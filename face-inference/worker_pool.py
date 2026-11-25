"""Reusable pool of pre-warmed, isolated child workers using binary length-prefixed framing."""

from __future__ import annotations

import collections
import contextlib
from dataclasses import dataclass
import os
import selectors
import signal
import struct
import subprocess
import sys
import threading
import time
from typing import Callable, Sequence

MAX_BYTES = 20 * 1024 * 1024
MAX_RESPONSE_BYTES = 16 * 1024 * 1024
STATUS_OK = 0
STATUS_ERROR = 1
DEFAULT_TIMEOUT_SECONDS = 45.0
DEFAULT_MAX_REQUESTS = 200
_DEFAULT_TOTAL_MEMORY_BYTES = int(1.2 * 1024**3)
_CHUNK_SIZE = 65536

SAFE_ENV_KEYS = (
    "PATH",
    "LD_LIBRARY_PATH",
    "DYLD_LIBRARY_PATH",
    "HOME",
    "TMPDIR",
    "LANG",
    "LC_ALL",
)


class WorkerBusyError(Exception):
    """Raised immediately when all worker slots are occupied."""


class WorkerTimeoutError(Exception):
    """Raised when a worker exceeds the per-request wall timeout."""


class WorkerPoolClosedError(Exception):
    """Raised when a worker pool is closing or closed (retryable 503)."""


class WorkerFailedError(Exception):
    """Raised when a worker crashes, closes stdout early, or sends malformed framing."""


@dataclass(frozen=True)
class WorkerResult:
    ok: bool
    payload: bytes
    worker_pid: int | None = None


def parse_worker_count(env_name: str, *, default: int = 1, minimum: int = 1, maximum: int = 4) -> int:
    raw = os.environ.get(env_name, "").strip()
    if not raw:
        return default
    value = int(raw)
    return max(minimum, min(maximum, value))


def parse_max_requests(env_name: str = "MAX_REQUESTS_PER_WORKER", *, default: int = DEFAULT_MAX_REQUESTS) -> int:
    raw = os.environ.get(env_name, "").strip()
    if not raw:
        return default
    value = int(raw)
    if value < 1:
        raise ValueError(f"{env_name} must be at least 1")
    return value


def resolve_memory_limit_bytes(workers: int, memory_mb: int | None = None) -> int:
    if memory_mb is None:
        raw = os.environ.get("WORKER_MEMORY_MB", "").strip()
        if raw:
            memory_mb = int(raw)
    if memory_mb is not None:
        if memory_mb <= 0:
            raise ValueError("WORKER_MEMORY_MB must be positive")
        return memory_mb * 1024 * 1024
    return int(_DEFAULT_TOTAL_MEMORY_BYTES // max(1, workers))


def sanitized_worker_env(
    *,
    memory_limit_bytes: int | None = None,
    base_env: dict[str, str] | None = None,
) -> dict[str, str]:
    """Build a minimal child environment excluding secrets like INFERENCE_KEY and DERIVATIVE_KEY."""
    source = os.environ if base_env is None else base_env
    env = {key: source[key] for key in SAFE_ENV_KEYS if key in source}
    env["OPENBLAS_NUM_THREADS"] = "1"
    env["OMP_NUM_THREADS"] = "1"
    env["PYTHONDONTWRITEBYTECODE"] = "1"
    if memory_limit_bytes is not None:
        env["WORKER_MEMORY_BYTES"] = str(memory_limit_bytes)
    return env


def apply_worker_limits(default_bytes: int = _DEFAULT_TOTAL_MEMORY_BYTES) -> None:
    """Apply Linux per-worker address space limit without setting cumulative RLIMIT_CPU."""
    if sys.platform != "linux":
        return
    import resource

    raw_bytes = os.environ.get("WORKER_MEMORY_BYTES", "").strip()
    raw_mb = os.environ.get("WORKER_MEMORY_MB", "").strip()
    if raw_bytes:
        limit = int(raw_bytes)
    elif raw_mb:
        limit = int(raw_mb) * 1024 * 1024
    else:
        limit = default_bytes
    if limit <= 0:
        raise ValueError("worker memory limit must be positive")
    _, hard = resource.getrlimit(resource.RLIMIT_AS)
    if hard != resource.RLIM_INFINITY:
        limit = min(limit, hard)
    resource.setrlimit(resource.RLIMIT_AS, (limit, limit))


def _read_exact(stream, length: int, *, allow_eof_at_start: bool) -> bytes | None:
    if length == 0:
        return b""
    buf = bytearray()
    while len(buf) < length:
        chunk = stream.read(length - len(buf))
        if not chunk:
            if allow_eof_at_start and not buf:
                return None
            raise EOFError("truncated_frame")
        buf.extend(chunk)
    return bytes(buf)


def read_request_frame(stream, *, max_bytes: int = MAX_BYTES) -> bytes | None:
    """Read one parent->child framed request. Returns None on clean EOF."""
    header = _read_exact(stream, 4, allow_eof_at_start=True)
    if header is None:
        return None
    (length,) = struct.unpack(">I", header)
    if length > max_bytes:
        raise ValueError("frame_too_large")
    return _read_exact(stream, length, allow_eof_at_start=False)


def write_response_frame(
    stream,
    ok: bool,
    body: bytes,
    *,
    max_response_bytes: int = MAX_RESPONSE_BYTES,
) -> None:
    """Write one child->parent framed response."""
    status = STATUS_OK if ok else STATUS_ERROR
    if not body or len(body) > max_response_bytes:
        status = STATUS_ERROR
        body = b'{"error":"response_limit"}'
    stream.write(struct.pack(">BI", status, len(body)))
    stream.write(body)
    stream.flush()


def serve_worker(
    handler: Callable[[bytes], tuple[bool, bytes]],
    *,
    error_payload: bytes,
    max_bytes: int = MAX_BYTES,
    max_response_bytes: int = MAX_RESPONSE_BYTES,
) -> None:
    """Run the framed stdin/stdout request loop inside an isolated worker process."""
    in_stream = sys.stdin.buffer
    out_stream = sys.stdout.buffer
    # Prevent accidental print() calls from corrupting binary framing on stdout.
    sys.stdout = sys.stderr
    while True:
        payload = read_request_frame(in_stream, max_bytes=max_bytes)
        if payload is None:
            return
        try:
            ok, body = handler(payload)
        except MemoryError:
            raise
        except Exception:
            ok, body = False, error_payload
        try:
            write_response_frame(out_stream, ok, body, max_response_bytes=max_response_bytes)
        except BrokenPipeError:
            return


class _Worker:
    def __init__(self, cmd: Sequence[str], *, env: dict[str, str], max_response_bytes: int):
        self._proc = subprocess.Popen(
            list(cmd),
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            env=env,
            bufsize=0,
            close_fds=True,
            start_new_session=True,
        )
        assert self._proc.stdin is not None and self._proc.stdout is not None
        os.set_blocking(self._proc.stdin.fileno(), False)
        os.set_blocking(self._proc.stdout.fileno(), False)
        self._max_response_bytes = max_response_bytes
        self.requests_handled = 0
        self._pipes_closed = False

    @property
    def pid(self) -> int:
        return self._proc.pid

    def is_alive(self) -> bool:
        return self._proc.poll() is None

    def request(self, payload: bytes, *, timeout: float) -> tuple[bool, bytes]:
        assert self._proc.stdin is not None and self._proc.stdout is not None
        stdin_fd = self._proc.stdin.fileno()
        stdout_fd = self._proc.stdout.fileno()
        payload_view = memoryview(payload)
        header = struct.pack(">I", len(payload_view))
        outgoing: list[memoryview] = [memoryview(header)]
        if len(payload_view) > 0:
            outgoing.append(payload_view)

        resp_header = bytearray()
        resp_body = bytearray()
        resp_status: int | None = None
        resp_len: int | None = None
        deadline = time.monotonic() + timeout

        with selectors.DefaultSelector() as selector:
            selector.register(stdout_fd, selectors.EVENT_READ)
            selector.register(stdin_fd, selectors.EVENT_WRITE)

            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise WorkerTimeoutError("worker_timeout")
                events = selector.select(timeout=remaining)
                if not events:
                    raise WorkerTimeoutError("worker_timeout")

                # Drain outbound writes before reading so protocol completion sees empty outgoing.
                ready_fds = [key.fileobj for key, _ in events]
                if stdin_fd in ready_fds and outgoing:
                    chunk = outgoing[0]
                    try:
                        written = os.write(stdin_fd, chunk[:_CHUNK_SIZE])
                    except BlockingIOError:
                        written = -1
                    except OSError as exc:
                        raise WorkerFailedError("worker_write_failed") from exc
                    if written == 0:
                        raise WorkerFailedError("worker_write_failed")
                    if written > 0:
                        if written < len(chunk):
                            outgoing[0] = chunk[written:]
                        else:
                            outgoing.pop(0)
                        if not outgoing:
                            selector.unregister(stdin_fd)

                if stdout_fd in ready_fds:
                    if resp_len is None:
                        need = 5 - len(resp_header)
                        try:
                            data = os.read(stdout_fd, need)
                        except BlockingIOError:
                            data = None
                        except OSError as exc:
                            raise WorkerFailedError("worker_read_failed") from exc
                        if data == b"":
                            raise WorkerFailedError("worker_eof")
                        if data:
                            resp_header.extend(data)
                            if len(resp_header) == 5:
                                resp_status, resp_len = struct.unpack(">BI", resp_header)
                                if (
                                    resp_status not in (STATUS_OK, STATUS_ERROR)
                                    or resp_len == 0
                                    or resp_len > self._max_response_bytes
                                ):
                                    raise WorkerFailedError("worker_malformed_frame")
                    else:
                        need = resp_len - len(resp_body)
                        try:
                            data = os.read(stdout_fd, min(need, _CHUNK_SIZE))
                        except BlockingIOError:
                            data = None
                        except OSError as exc:
                            raise WorkerFailedError("worker_read_failed") from exc
                        if data == b"":
                            raise WorkerFailedError("worker_eof")
                        if data:
                            resp_body.extend(data)

                    if resp_len is not None and len(resp_body) == resp_len:
                        if outgoing:
                            raise WorkerFailedError("worker_protocol_desync")
                        return resp_status == STATUS_OK, bytes(resp_body)

    def terminate(self) -> None:
        if self._proc.poll() is None:
            try:
                os.killpg(self._proc.pid, signal.SIGKILL)
            except (ProcessLookupError, PermissionError, OSError):
                pass
            try:
                self._proc.kill()
            except (ProcessLookupError, OSError):
                pass

    def wait_reaped(self) -> None:
        try:
            self._proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.terminate()
            self._proc.wait()

    def _close_pipes(self) -> None:
        if self._pipes_closed:
            return
        self._pipes_closed = True
        for pipe in (self._proc.stdin, self._proc.stdout):
            if pipe is not None:
                try:
                    pipe.close()
                except OSError:
                    pass

    def kill(self) -> None:
        self.terminate()
        self.wait_reaped()
        self._close_pipes()

    def retire(self, grace_seconds: float = 2.0) -> None:
        if self._proc.stdin is not None:
            try:
                self._proc.stdin.close()
            except OSError:
                pass
        try:
            self._proc.wait(timeout=grace_seconds)
        except subprocess.TimeoutExpired:
            self.terminate()
            self.wait_reaped()
        self._close_pipes()


class WorkerPool:
    """Bounded pool of pre-warmed, isolated child processes with non-blocking admission."""

    def __init__(
        self,
        cmd: Sequence[str],
        *,
        workers: int = 1,
        timeout: float = DEFAULT_TIMEOUT_SECONDS,
        max_requests: int = DEFAULT_MAX_REQUESTS,
        max_bytes: int = MAX_BYTES,
        max_response_bytes: int = MAX_RESPONSE_BYTES,
        memory_limit_mb: int | None = None,
        prewarm: bool = False,
    ):
        if workers < 1:
            raise ValueError("workers must be at least 1")
        if timeout <= 0:
            raise ValueError("timeout must be positive")
        if max_requests < 1:
            raise ValueError("max_requests must be at least 1")
        if max_bytes < 1 or max_response_bytes < 1:
            raise ValueError("frame size limits must be positive")
        self._cmd = tuple(cmd)
        self._workers = workers
        self._timeout = float(timeout)
        self._max_requests = max_requests
        self._max_bytes = max_bytes
        self._max_response_bytes = max_response_bytes
        self._memory_limit_bytes = resolve_memory_limit_bytes(workers, memory_limit_mb)
        self._gate = threading.BoundedSemaphore(workers)
        self._lock = threading.Lock()
        self._idle: collections.deque[_Worker] = collections.deque()
        self._active: set[_Worker] = set()
        self._closed = False
        if prewarm:
            self.warm()

    @property
    def workers(self) -> int:
        return self._workers

    @property
    def timeout(self) -> float:
        return self._timeout

    @property
    def max_requests(self) -> int:
        return self._max_requests

    @property
    def memory_limit_bytes(self) -> int:
        return self._memory_limit_bytes

    def _spawn(self) -> _Worker:
        env = sanitized_worker_env(memory_limit_bytes=self._memory_limit_bytes)
        return _Worker(self._cmd, env=env, max_response_bytes=self._max_response_bytes)

    def warm(self) -> None:
        """Pre-spawn up to `workers` idle child processes."""
        for _ in range(self._workers):
            if not self._gate.acquire(blocking=False):
                break
            try:
                with self._lock:
                    if self._closed or len(self._idle) + len(self._active) >= self._workers:
                        continue
                worker = self._spawn()
                with self._lock:
                    if self._closed:
                        worker.kill()
                    else:
                        self._idle.append(worker)
            finally:
                self._gate.release()

    @contextlib.contextmanager
    def slot(self):
        """Acquire a non-blocking admission slot or fail immediately with WorkerBusyError."""
        if self._closed:
            raise WorkerPoolClosedError("pool_closed")
        if not self._gate.acquire(blocking=False):
            raise WorkerBusyError("workers_busy")
        try:
            yield
        finally:
            self._gate.release()

    def execute(self, payload: bytes, *, timeout: float | None = None, acquired: bool = False) -> WorkerResult:
        if not isinstance(payload, (bytes, bytearray, memoryview)):
            raise ValueError("payload_must_be_bytes")
        if len(payload) > self._max_bytes:
            raise ValueError("payload_limit")
        if not acquired:
            with self.slot():
                return self._dispatch(payload, timeout=timeout)
        return self._dispatch(payload, timeout=timeout)

    def _dispatch(self, payload: bytes, *, timeout: float | None = None) -> WorkerResult:
        effective_timeout = self._timeout if timeout is None else float(timeout)
        if effective_timeout <= 0:
            raise ValueError("timeout must be positive")
        worker: _Worker | None = None
        dead: list[_Worker] = []
        with self._lock:
            if self._closed:
                raise WorkerPoolClosedError("pool_closed")
            while self._idle:
                candidate = self._idle.popleft()
                if candidate.is_alive():
                    worker = candidate
                    break
                dead.append(candidate)
        for stale in dead:
            stale.kill()

        if worker is None:
            worker = self._spawn()

        with self._lock:
            if self._closed:
                worker.kill()
                raise WorkerPoolClosedError("pool_closed")
            self._active.add(worker)

        keep_worker = False
        killed = False
        try:
            ok, body = worker.request(payload, timeout=effective_timeout)
            worker.requests_handled += 1
            keep_worker = worker.requests_handled < self._max_requests and worker.is_alive()
            return WorkerResult(ok=ok, payload=body, worker_pid=worker.pid)
        except BaseException:
            worker.kill()
            killed = True
            if self._closed:
                raise WorkerPoolClosedError("pool_closed") from None
            raise
        finally:
            with self._lock:
                self._active.discard(worker)
                if keep_worker and not self._closed:
                    self._idle.append(worker)
                else:
                    keep_worker = False
            if not keep_worker and not killed:
                worker.retire()

    def close(self) -> None:
        """Kill and reap all idle and active worker child processes."""
        with self._lock:
            self._closed = True
            idle = list(self._idle)
            active = list(self._active)
            self._idle.clear()
        for worker in idle:
            worker.kill()
        for worker in active:
            worker.terminate()
        for worker in active:
            worker.wait_reaped()

    def __enter__(self) -> WorkerPool:
        return self

    def __exit__(self, *_args) -> None:
        self.close()
