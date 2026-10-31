import hmac
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import subprocess
import sys
import threading

MAX_BYTES = 20 * 1024 * 1024
gate = threading.BoundedSemaphore(1)
key = os.environ["INFERENCE_KEY"]
if len(key) < 32:
    raise RuntimeError("INFERENCE_KEY must contain at least 32 characters")
root = Path(__file__).resolve().parent
manifest = json.loads((root / "models.json").read_text())
for model in manifest["models"]:
    if hashlib.sha256((root / "models" / model["file"]).read_bytes()).hexdigest() != model["sha256"]:
        raise RuntimeError("Model checksum failed at startup")


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
        if self.path not in ("/v1/infer", "/infer") or not hmac.compare_digest(
            self.headers.get("X-Nephos-Inference-Key", ""), key
        ):
            self.reply(403, b"{}")
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            length = 0
        if not 0 < length <= MAX_BYTES or self.headers.get("Transfer-Encoding"):
            self.reply(413, b"{}")
            return
        if not gate.acquire(blocking=False):
            self.reply(429, b"{}")
            return
        try:
            data = self.rfile.read(length)
            if len(data) != length:
                self.reply(400, b"{}")
                return
            result = subprocess.run(
                [sys.executable, str(Path(__file__).with_name("infer.py"))],
                input=data,
                capture_output=True,
                timeout=45,
                check=False,
            )
            self.reply(200 if result.returncode == 0 else 422, result.stdout or b'{"error":"inference_rejected"}')
        except subprocess.TimeoutExpired:
            self.reply(422, b'{"error":"inference_timeout"}')
        except (OSError, ValueError):
            self.reply(400, b'{"error":"invalid_request"}')
        finally:
            gate.release()


ThreadingHTTPServer(("0.0.0.0", 8090), Handler).serve_forever()
