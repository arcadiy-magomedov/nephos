"""Transport compatibility is independent of model/pipeline versioning."""

import io
import os
from pathlib import Path
import runpy
import sys
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parent
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from worker_pool import (  # noqa: E402
    WorkerBusyError,
    WorkerFailedError,
    WorkerPoolClosedError,
    WorkerResult,
    WorkerTimeoutError,
)


class ApiVersionTests(unittest.TestCase):
    def test_v1_and_legacy_routes_share_authentication_and_processing(self):
        for file, setting, header, route in (
            ("server.py", "INFERENCE_KEY", "X-Nephos-Inference-Key", "infer"),
            ("derivative_server.py", "DERIVATIVE_KEY", "X-Nephos-Service-Key", "render"),
        ):
            with patch.dict(os.environ, {setting: "k" * 32}), patch("http.server.ThreadingHTTPServer"):
                server = runpy.run_path(str(ROOT / file))
            for path in ("/" + route, "/v1/" + route, "/v2/" + route):
                for authorized in (False, True):
                    with self.subTest(service=file, path=path, authorized=authorized):
                        handler = object.__new__(server["Handler"])
                        handler.connection = Mock()
                        handler.path = path
                        handler.headers = {"Content-Length": "4", header: "k" * 32 if authorized else "wrong"}
                        handler.rfile = io.BytesIO(b"body")
                        handler.reply = Mock()
                        result = WorkerResult(ok=True, payload=b'{"fixture":true}')
                        with patch.object(server["pool"], "execute", return_value=result) as child:
                            handler.do_POST()
                            if authorized and not path.startswith("/v2/"):
                                self.assertEqual(b"body", child.call_args.args[0])
                                handler.reply.assert_called_once_with(200, result.payload)
                            else:
                                child.assert_not_called()
                                handler.reply.assert_called_once_with(403, b"{}")

    def test_status_codes_and_worker_count_bounds(self):
        cases = (
            ("server.py", "INFERENCE_KEY", "INFERENCE_WORKERS", 4, "X-Nephos-Inference-Key", "/infer", "inference"),
            (
                "derivative_server.py",
                "DERIVATIVE_KEY",
                "DERIVATIVE_WORKERS",
                2,
                "X-Nephos-Service-Key",
                "/render",
                "render",
            ),
        )
        for file, key_var, workers_var, max_workers, header, route, prefix in cases:
            with (
                patch.dict(os.environ, {key_var: "k" * 32, workers_var: "99"}),
                patch("http.server.ThreadingHTTPServer"),
            ):
                server = runpy.run_path(str(ROOT / file))
            self.assertEqual(max_workers, server["pool"].workers)

            handler = object.__new__(server["Handler"])
            handler.path = "/health"
            handler.reply = Mock()
            handler.do_GET()
            handler.reply.assert_called_once_with(200, b"{}")

            handler.path = "/unknown"
            handler.reply = Mock()
            handler.do_GET()
            handler.reply.assert_called_once_with(404, b"{}")

            for outcome, expected_status, expected_body in (
                (WorkerResult(ok=False, payload=b'{"error":"corrupt_image"}'), 422, b'{"error":"corrupt_image"}'),
                (WorkerTimeoutError("timeout"), 422, f'{{"error":"{prefix}_timeout"}}'.encode()),
                (WorkerFailedError("crash"), 422, f'{{"error":"{prefix}_rejected"}}'.encode()),
                (WorkerPoolClosedError("pool_closed"), 503, b'{"error":"service_shutting_down"}'),
                (WorkerBusyError("busy"), 429, b"{}"),
            ):
                with self.subTest(service=file, expected_status=expected_status, expected_body=expected_body):
                    handler = object.__new__(server["Handler"])
                    handler.connection = Mock()
                    handler.path = route
                    handler.headers = {"Content-Length": "4", header: "k" * 32}
                    handler.rfile = io.BytesIO(b"body")
                    handler.reply = Mock()
                    if isinstance(outcome, Exception):
                        patcher = patch.object(server["pool"], "execute", side_effect=outcome)
                    else:
                        patcher = patch.object(server["pool"], "execute", return_value=outcome)
                    with patcher:
                        handler.do_POST()
                    handler.reply.assert_called_once_with(expected_status, expected_body)

            # Saturating the real pool slot returns 429 before reading body or invoking execute.
            handler = object.__new__(server["Handler"])
            handler.connection = Mock()
            handler.path = route
            handler.headers = {"Content-Length": "4", header: "k" * 32}
            handler.rfile = Mock()
            handler.reply = Mock()
            with patch.object(server["pool"], "slot", side_effect=WorkerBusyError("busy")):
                with patch.object(server["pool"], "execute") as execute:
                    handler.do_POST()
                    execute.assert_not_called()
            handler.rfile.read.assert_not_called()
            handler.reply.assert_called_once_with(429, b"{}")
