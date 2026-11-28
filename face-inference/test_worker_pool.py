"""Tests for the pre-warmed, isolated WorkerPool and binary framing protocol."""

import io
import json
import os
import struct
import sys
import threading
import time
import unittest
from array import array
from pathlib import Path
from unittest.mock import MagicMock, patch

ROOT = Path(__file__).resolve().parent
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from worker_pool import (  # noqa: E402
    STATUS_ERROR,
    WorkerBusyError,
    WorkerFailedError,
    WorkerPool,
    WorkerPoolClosedError,
    WorkerTimeoutError,
    apply_worker_limits,
    read_request_frame,
    resolve_memory_limit_bytes,
    serve_worker,
    write_response_frame,
)

DUMMY_WORKER_CODE = f"""
import json
import os
import struct
import sys
import time

sys.path.insert(0, {str(ROOT)!r})
from worker_pool import MAX_RESPONSE_BYTES, serve_worker

raw_out = sys.stdout.buffer

def handle(payload):
    text = payload.decode("utf-8", errors="replace")
    if text.startswith("echo:"):
        return True, json.dumps({{"pid": os.getpid(), "echo": text[5:]}}).encode("utf-8")
    if text == "env":
        return True, json.dumps({{"pid": os.getpid(), "env": dict(os.environ)}}).encode("utf-8")
    if text.startswith("reject:"):
        return False, json.dumps({{"pid": os.getpid(), "error": text[7:]}}).encode("utf-8")
    if text.startswith("sleep:"):
        time.sleep(float(text[6:]))
        return True, json.dumps({{"pid": os.getpid(), "slept": True}}).encode("utf-8")
    if text == "crash":
        os._exit(137)
    if text == "eof":
        os.close(raw_out.fileno())
        os._exit(0)
    if text == "malformed_status":
        raw_out.write(struct.pack(">BI", 9, 2) + b"{{}}")
        raw_out.flush()
        time.sleep(5)
    if text == "malformed_oversized":
        raw_out.write(struct.pack(">BI", 0, MAX_RESPONSE_BYTES + 1))
        raw_out.flush()
        time.sleep(5)
    if text == "malformed_zero":
        raw_out.write(struct.pack(">BI", 0, 0))
        raw_out.flush()
        time.sleep(5)
    if text == "print_stdout":
        print("stray stdout text must not corrupt framing")
        return True, json.dumps({{"pid": os.getpid(), "ok": True}}).encode("utf-8")
    return True, json.dumps({{"pid": os.getpid(), "length": len(payload)}}).encode("utf-8")

serve_worker(handle, error_payload=b'{{"error":"worker_error"}}')
"""

DUMMY_CMD = [sys.executable, "-c", DUMMY_WORKER_CODE]
HUNG_BEFORE_READ_CMD = [sys.executable, "-c", "import time; time.sleep(30)"]


def _pid_exists(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def _has_media_deps() -> bool:
    try:
        import cv2  # noqa: F401
        import pillow_heif  # noqa: F401
        from PIL import Image  # noqa: F401
    except ImportError:
        return False
    return True


class WorkerPoolTests(unittest.TestCase):
    def test_unexpected_handler_failures_report_only_exception_type(self):
        input_stream = io.BytesIO(struct.pack(">I", 4) + b"body")
        output_stream = io.BytesIO()
        with (
            patch.object(sys, "stdin", MagicMock(buffer=input_stream)),
            patch.object(sys, "stdout", MagicMock(buffer=output_stream)),
            self.assertLogs("worker_pool", level="ERROR") as logs,
        ):
            serve_worker(
                MagicMock(side_effect=RuntimeError("secret image details")), error_payload=b'{"error":"failed"}'
            )
        self.assertIn("RuntimeError", logs.output[0])
        self.assertNotIn("secret image", logs.output[0])
        self.assertEqual(b'{"error":"failed"}', output_stream.getvalue()[5:])

    def test_warm_worker_reuse_keeps_same_pid(self):
        with WorkerPool(DUMMY_CMD, workers=1, timeout=5, max_requests=10, prewarm=True) as pool:
            r1 = pool.execute(b"echo:one")
            r2 = pool.execute(b"reject:bad_image")
            r3 = pool.execute(b"echo:two")
            r4 = pool.execute(b"print_stdout")
        self.assertTrue(r1.ok)
        self.assertFalse(r2.ok)
        self.assertTrue(r3.ok)
        self.assertTrue(r4.ok)
        self.assertEqual("one", json.loads(r1.payload)["echo"])
        self.assertEqual("bad_image", json.loads(r2.payload)["error"])
        self.assertEqual("two", json.loads(r3.payload)["echo"])
        self.assertEqual(r1.worker_pid, r2.worker_pid)
        self.assertEqual(r1.worker_pid, r3.worker_pid)
        self.assertEqual(r1.worker_pid, r4.worker_pid)

    def test_automatic_recycling_after_max_requests(self):
        with WorkerPool(DUMMY_CMD, workers=1, timeout=5, max_requests=3, prewarm=True) as pool:
            first_batch = [pool.execute(f"echo:{i}".encode()) for i in range(3)]
            first_pid = first_batch[0].worker_pid
            self.assertEqual([first_pid] * 3, [r.worker_pid for r in first_batch])
            self.assertFalse(_pid_exists(first_pid))

            second_batch = [pool.execute(f"echo:{i}".encode()) for i in range(3, 6)]
            second_pid = second_batch[0].worker_pid
            self.assertNotEqual(first_pid, second_pid)
            self.assertEqual([second_pid] * 3, [r.worker_pid for r in second_batch])
            self.assertFalse(_pid_exists(second_pid))

            seventh = pool.execute(b"echo:6")
            self.assertNotEqual(second_pid, seventh.worker_pid)

    def test_timeout_kills_hung_child_and_respawns_lazily(self):
        with WorkerPool(DUMMY_CMD, workers=1, timeout=0.35, max_requests=10, prewarm=True) as pool:
            first = pool.execute(b"echo:warm")
            first_pid = first.worker_pid
            with self.assertRaises(WorkerTimeoutError):
                pool.execute(b"sleep:10")
            self.assertFalse(_pid_exists(first_pid))

            recovered = pool.execute(b"echo:after_timeout")
            self.assertTrue(recovered.ok)
            self.assertEqual("after_timeout", json.loads(recovered.payload)["echo"])
            self.assertNotEqual(first_pid, recovered.worker_pid)

    def test_timeout_does_not_deadlock_on_large_payload_when_child_never_reads(self):
        with WorkerPool(HUNG_BEFORE_READ_CMD, workers=1, timeout=0.35, prewarm=True) as pool:
            started = time.monotonic()
            with self.assertRaises(WorkerTimeoutError):
                pool.execute(b"X" * 262_144)
            self.assertLess(time.monotonic() - started, 2.0)

    def test_linux_rlimit_as_is_proportional_and_skips_rlimit_cpu(self):
        one = resolve_memory_limit_bytes(1)
        two = resolve_memory_limit_bytes(2)
        self.assertEqual(one // 2, two)
        self.assertLess(one, 1536 * 1024 * 1024)
        with patch.dict(os.environ, {"WORKER_MEMORY_MB": "512"}):
            self.assertEqual(512 * 1024 * 1024, resolve_memory_limit_bytes(4))

        fake_resource = MagicMock()
        fake_resource.RLIMIT_AS = 9
        fake_resource.RLIMIT_CPU = 0
        fake_resource.RLIM_INFINITY = -1
        fake_resource.getrlimit.return_value = (1024**3, 1024**3)
        with (
            patch.object(sys, "platform", "linux"),
            patch.dict(sys.modules, {"resource": fake_resource}),
            patch.dict(os.environ, {"WORKER_MEMORY_BYTES": str(2 * 1024**3)}, clear=False),
        ):
            apply_worker_limits()
        fake_resource.setrlimit.assert_called_once_with(fake_resource.RLIMIT_AS, (1024**3, 1024**3))

    def test_crashing_and_malformed_children_recover_on_fresh_worker(self):
        for trigger in (b"crash", b"eof", b"malformed_status", b"malformed_oversized", b"malformed_zero"):
            with (
                self.subTest(trigger=trigger.decode()),
                WorkerPool(DUMMY_CMD, workers=1, timeout=2, max_requests=10, prewarm=True) as pool,
            ):
                first = pool.execute(b"echo:before")
                first_pid = first.worker_pid
                with self.assertRaises(WorkerFailedError):
                    pool.execute(trigger)
                self.assertFalse(_pid_exists(first_pid))

                recovered = pool.execute(b"echo:after")
                self.assertTrue(recovered.ok)
                self.assertEqual("after", json.loads(recovered.payload)["echo"])
                self.assertNotEqual(first_pid, recovered.worker_pid)

    def test_secret_env_vars_are_stripped_from_child_environment(self):
        secrets = {
            "INFERENCE_KEY": "i" * 40,
            "DERIVATIVE_KEY": "d" * 40,
            "SERVICE_KEY": "s" * 40,
            "POSTGRES_PASSWORD": "secret-db-password",
        }
        with patch.dict(os.environ, secrets), WorkerPool(DUMMY_CMD, workers=1, timeout=5, prewarm=True) as pool:
            result = pool.execute(b"env")
            expected_mem = str(pool.memory_limit_bytes)
        self.assertTrue(result.ok)
        child_env = json.loads(result.payload)["env"]
        for secret in secrets:
            self.assertNotIn(secret, child_env)
        self.assertEqual("1", child_env["OPENBLAS_NUM_THREADS"])
        self.assertEqual("1", child_env["OMP_NUM_THREADS"])
        self.assertEqual("1", child_env["PYTHONDONTWRITEBYTECODE"])
        self.assertEqual(expected_mem, child_env["WORKER_MEMORY_BYTES"])

    def test_concurrency_saturation_returns_busy_immediately(self):
        for count in (1, 2):
            with (
                self.subTest(workers=count),
                WorkerPool(DUMMY_CMD, workers=count, timeout=5, prewarm=True) as pool,
            ):
                results = []
                errors = []

                def run_slow(results=results, errors=errors):
                    try:
                        results.append(pool.execute(b"sleep:0.4"))
                    except Exception as exc:
                        errors.append(exc)

                threads = [threading.Thread(target=run_slow) for _ in range(count)]
                for thread in threads:
                    thread.start()

                deadline = time.monotonic() + 3.0
                while time.monotonic() < deadline:
                    with pool._lock:
                        if len(pool._active) == count:
                            break
                    time.sleep(0.01)
                else:
                    self.fail("Workers did not become active in time")

                started = time.monotonic()
                with self.assertRaises(WorkerBusyError):
                    pool.execute(b"echo:saturated")
                self.assertLess(time.monotonic() - started, 0.2)

                for thread in threads:
                    thread.join(timeout=5)
                self.assertEqual([], errors)
                self.assertEqual(count, len(results))
                self.assertTrue(all(r.ok for r in results))

                after = pool.execute(b"echo:free")
                self.assertTrue(after.ok)
                self.assertEqual("free", json.loads(after.payload)["echo"])

    def test_large_payload_and_strict_frame_length_validation(self):
        with WorkerPool(DUMMY_CMD, workers=1, timeout=5, max_bytes=300_000, prewarm=True) as pool:
            big = b"A" * 262_144
            r1 = pool.execute(big)
            self.assertTrue(r1.ok)
            self.assertEqual(262_144, json.loads(r1.payload)["length"])

            with self.assertRaisesRegex(ValueError, "^payload_limit$"):
                pool.execute(b"B" * 300_001)

            r2 = pool.execute(b"echo:still_warm")
            self.assertEqual(r1.worker_pid, r2.worker_pid)

        self.assertIsNone(read_request_frame(io.BytesIO(b"")))
        with self.assertRaisesRegex(ValueError, "^frame_too_large$"):
            read_request_frame(io.BytesIO(struct.pack(">I", 101)), max_bytes=100)
        with self.assertRaises(EOFError):
            read_request_frame(io.BytesIO(b"\x00\x01"))
        with self.assertRaises(EOFError):
            read_request_frame(io.BytesIO(struct.pack(">I", 10) + b"short"))

        out = io.BytesIO()
        write_response_frame(out, True, b"x" * 101, max_response_bytes=100)
        status, length = struct.unpack(">BI", out.getvalue()[:5])
        self.assertEqual(STATUS_ERROR, status)
        self.assertEqual(b'{"error":"response_limit"}', out.getvalue()[5 : 5 + length])

    def test_memoryview_limits_and_framing_count_bytes_not_elements(self):
        data = memoryview(array("I", [1, 2, 3]))
        with WorkerPool(DUMMY_CMD, max_bytes=data.nbytes) as pool:
            response = pool.execute(data)
            self.assertEqual(data.nbytes, json.loads(response.payload)["length"])
            response = pool.execute(data[::2])
            self.assertEqual(data[::2].nbytes, json.loads(response.payload)["length"])
        with (
            WorkerPool(DUMMY_CMD, max_bytes=data.nbytes - 1) as pool,
            self.assertRaisesRegex(ValueError, "payload_limit"),
        ):
            pool.execute(data)

    def test_nonfinite_timeouts_rejected_before_launching_worker(self):
        for timeout in (float("nan"), float("inf"), -float("inf"), 0):
            with self.subTest(timeout=timeout), self.assertRaisesRegex(ValueError, "finite and positive"):
                WorkerPool(DUMMY_CMD, timeout=timeout)
            with WorkerPool(DUMMY_CMD) as pool, self.subTest(timeout=timeout), patch.object(pool, "_spawn") as spawn:
                with self.assertRaisesRegex(ValueError, "finite and positive"):
                    pool.execute(b"echo:timeout", timeout=timeout)
                spawn.assert_not_called()

    def test_close_kills_idle_and_active_workers_cleanly(self):
        pool = WorkerPool(DUMMY_CMD, workers=1, timeout=5, prewarm=True)
        first = pool.execute(b"echo:pid")
        pid = first.worker_pid
        self.assertTrue(_pid_exists(pid))
        pool.close()
        self.assertFalse(_pid_exists(pid))
        with self.assertRaises(WorkerPoolClosedError):
            pool.execute(b"echo:after_close")

        active_pool = WorkerPool(DUMMY_CMD, workers=1, timeout=10, prewarm=True)
        error_holder = []

        def run_blocked():
            try:
                active_pool.execute(b"sleep:10")
            except Exception as exc:
                error_holder.append(exc)

        thread = threading.Thread(target=run_blocked)
        thread.start()
        deadline = time.monotonic() + 3.0
        active_pid = None
        while time.monotonic() < deadline:
            with active_pool._lock:
                if active_pool._active:
                    active_pid = next(iter(active_pool._active)).pid
                    break
            time.sleep(0.01)
        self.assertIsNotNone(active_pid)
        active_pool.close()
        thread.join(timeout=5)
        self.assertFalse(_pid_exists(active_pid))
        self.assertEqual(1, len(error_holder))
        self.assertIsInstance(error_holder[0], WorkerPoolClosedError)

    @unittest.skipUnless(
        _has_media_deps()
        and all(
            (ROOT / "models" / filename).exists()
            for filename in ("face_detection_yunet_2023mar.onnx", "face_recognition_sface_2021dec.onnx")
        ),
        "Requires media dependencies and pinned local models",
    )
    def test_real_inference_and_derivative_workers_reuse_and_handle_errors(self):
        from PIL import Image

        encoded = io.BytesIO()
        Image.new("RGB", (320, 240), "white").save(encoded, format="PNG")
        png_bytes = encoded.getvalue()

        with WorkerPool([sys.executable, str(ROOT / "derivatives.py"), "--worker"], workers=1, timeout=45) as pool:
            ok1 = pool.execute(png_bytes)
            bad = pool.execute(b"not an image")
            ok2 = pool.execute(png_bytes)
            self.assertTrue(ok1.ok)
            self.assertFalse(bad.ok)
            self.assertTrue(ok2.ok)
            self.assertEqual(ok1.worker_pid, bad.worker_pid)
            self.assertEqual(ok1.worker_pid, ok2.worker_pid)
            self.assertEqual({"error": "corrupt_image"}, json.loads(bad.payload))
            self.assertEqual({"512", "1280", "2560"}, set(json.loads(ok1.payload)["variants"]))

        with WorkerPool([sys.executable, str(ROOT / "infer.py"), "--worker"], workers=1, timeout=45) as pool:
            ok1 = pool.execute(png_bytes)
            bad = pool.execute(b"not an image")
            ok2 = pool.execute(png_bytes)
            self.assertTrue(ok1.ok)
            self.assertFalse(bad.ok)
            self.assertTrue(ok2.ok)
            self.assertEqual(ok1.worker_pid, bad.worker_pid)
            self.assertEqual(ok1.worker_pid, ok2.worker_pid)
            self.assertEqual([], json.loads(ok1.payload)["faces"])
            self.assertEqual({"error": "corrupt_image"}, json.loads(bad.payload))
            portrait = ROOT / "fixtures/photos/obama-2009.jpg"
            if portrait.exists():
                face_res = pool.execute(portrait.read_bytes())
                self.assertTrue(face_res.ok)
                self.assertEqual(ok1.worker_pid, face_res.worker_pid)
                self.assertEqual(1, len(json.loads(face_res.payload)["faces"]))


if __name__ == "__main__":
    unittest.main()
