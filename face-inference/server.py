import hashlib
import hmac
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import signal
import sys
import threading

root = Path(__file__).resolve().parent
if str(root) not in sys.path:
    sys.path.insert(0, str(root))

from worker_pool import (  # noqa: E402
    MAX_BYTES,
    WorkerBusyError,
    WorkerFailedError,
    WorkerPool,
    WorkerPoolClosedError,
    WorkerTimeoutError,
    parse_max_requests,
    parse_worker_count,
)

key = os.environ["INFERENCE_KEY"]
if len(key) < 32:
    raise RuntimeError("INFERENCE_KEY must contain at least 32 characters")
manifest = json.loads((root / "models.json").read_text())
for model in manifest["models"]:
    if hashlib.sha256((root / "models" / model["file"]).read_bytes()).hexdigest() != model["sha256"]:
        raise RuntimeError("Model checksum failed at startup")

workers = parse_worker_count("INFERENCE_WORKERS", default=1, minimum=1, maximum=4)
max_requests = parse_max_requests()
pool = WorkerPool(
    [sys.executable, str(root / "infer.py"), "--worker"],
    workers=workers,
    timeout=45,
    max_requests=max_requests,
)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def reply(self, status, payload):
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        self.reply(200 if self.path == "/health" else 404, b"{}")

    def do_POST(self):
        self.connection.settimeout(15)
        supplied = self.headers.get("X-Nephos-Inference-Key", "")
        if self.path not in ("/v1/infer", "/infer") or not hmac.compare_digest(supplied.encode(), key.encode()):
            self.reply(403, b"{}")
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            length = 0
        if not 0 < length <= MAX_BYTES or self.headers.get("Transfer-Encoding"):
            self.reply(413, b"{}")
            return
        try:
            with pool.slot():
                data = self.rfile.read(length)
                if len(data) != length:
                    self.reply(400, b"{}")
                    return
                result = pool.execute(data, acquired=True)
        except WorkerBusyError:
            self.reply(429, b"{}")
            return
        except WorkerPoolClosedError:
            self.reply(503, b'{"error":"service_shutting_down"}')
            return
        except WorkerTimeoutError:
            self.reply(422, b'{"error":"inference_timeout"}')
            return
        except WorkerFailedError:
            self.reply(422, b'{"error":"inference_rejected"}')
            return
        except (OSError, ValueError):
            self.reply(400, b'{"error":"invalid_request"}')
            return
        self.reply(200 if result.ok else 422, result.payload or b'{"error":"inference_rejected"}')


def run_server():
    httpd = None
    try:
        pool.warm()
        httpd = ThreadingHTTPServer(("0.0.0.0", 8090), Handler)

        def _shutdown(*_):
            threading.Thread(target=httpd.shutdown, daemon=True).start()

        signal.signal(signal.SIGTERM, _shutdown)
        httpd.serve_forever()
    finally:
        if httpd is not None:
            httpd.server_close()
        pool.close()


if __name__ == "__main__":
    run_server()
