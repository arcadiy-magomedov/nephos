#!/usr/bin/env python3
"""Verify generic background file uploads over trusted loopback TLS on a disposable simulator."""

import argparse
import hashlib
import http.server
import json
import os
from pathlib import Path
import re
import signal
import ssl
import subprocess
import tempfile
import threading
import time

from onboarding_qualification import BUNDLE, IOS, project


def run(*arguments, **kwargs):
    return subprocess.run(arguments, check=True, timeout=kwargs.pop("timeout", 120), **kwargs)


def wait_for(predicate, description, timeout=90):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.1)
    raise RuntimeError("Timed out waiting for " + description)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--simulator", required=True, help="A disposable simulator; trusts a fixture CA only here.")
    args = parser.parse_args()
    scratch = IOS / ".test-work"
    scratch.mkdir(exist_ok=True)
    expected = {
        "/upload/book.pdf": ("application/pdf", 5 * 1024 * 1024, 17),
        "/upload/book.epub": ("application/epub+zip", 1024 * 1024, 29),
        "/upload/empty.custom": ("application/x-nephos-fixture", 0, 0),
    }
    received = {}
    failures = []
    gate = threading.Event()
    state_lock = threading.Lock()

    class Receiver(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *_):
            pass

        def do_PUT(self):
            if self.path not in expected or self.headers.get("X-Fixture-Caller") != "fixture-only":
                self.send_error(400)
                return
            media_type, size, byte = expected[self.path]
            gate.wait(120)
            try:
                if self.headers.get("Content-Type") != media_type or self.headers.get("Content-Length") != str(size):
                    raise RuntimeError("The native transport changed caller metadata")
                digest = hashlib.sha256()
                remaining = size
                while remaining:
                    data = self.rfile.read(min(65536, remaining))
                    if not data:
                        raise RuntimeError("The native upload body ended early")
                    digest.update(data)
                    remaining -= len(data)
                if digest.digest() != hashlib.sha256(bytes([byte]) * size).digest():
                    raise RuntimeError("The native transport changed file bytes")
                self.send_response(204)
                self.send_header("Content-Length", "0")
                self.end_headers()
                with state_lock:
                    received[self.path] = True
            except Exception as error:
                with state_lock:
                    failures.append(str(error))
                self.send_error(500)

    with tempfile.TemporaryDirectory(prefix="generic-upload-", dir=scratch) as temporary:
        workspace = Path(temporary)
        certificate, key = workspace / "fixture.crt", workspace / "fixture.key"
        run(
            "openssl",
            "req",
            "-x509",
            "-newkey",
            "rsa:2048",
            "-nodes",
            "-days",
            "1",
            "-subj",
            "/CN=Nephos Generic Upload Fixture",
            "-keyout",
            str(key),
            "-out",
            str(certificate),
            "-addext",
            "subjectAltName=IP:127.0.0.1",
            "-addext",
            "basicConstraints=critical,CA:TRUE",
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        run("xcrun", "simctl", "keychain", args.simulator, "add-root-cert", str(certificate))
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Receiver)
        server.daemon_threads = True
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(certificate, key)
        server.socket = context.wrap_socket(server.socket, server_side=True)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        pid = None
        stopped = False
        try:
            destination = project(workspace)
            with (workspace / "build.log").open("w") as log:
                build = subprocess.run(
                    [
                        "xcodebuild",
                        "-quiet",
                        "-project",
                        str(destination),
                        "-target",
                        "NephosUIQualification",
                        "-configuration",
                        "Debug",
                        "-sdk",
                        "iphonesimulator",
                        "-destination",
                        "id=" + args.simulator,
                        "CONFIGURATION_BUILD_DIR=" + str(workspace / "products"),
                        "build",
                    ],
                    stdout=log,
                    stderr=subprocess.STDOUT,
                    timeout=600,
                )
            if build.returncode:
                errors = [line for line in (workspace / "build.log").read_text().splitlines() if ": error:" in line]
                raise RuntimeError("Native fixture build failed: " + "\n".join(errors[:8]))
            app = workspace / "products/NephosUIQualification.app"
            run(
                "codesign",
                "--force",
                "--sign",
                "-",
                "--identifier",
                BUNDLE,
                str(app),
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            run("xcrun", "simctl", "install", args.simulator, str(app))
            env = dict(os.environ)
            env["SIMCTL_CHILD_NEPHOS_UI_SCREEN"] = "generic-file-upload"
            env["SIMCTL_CHILD_NEPHOS_FILE_UPLOAD_ORIGIN"] = f"https://127.0.0.1:{server.server_port}"
            launched = run("xcrun", "simctl", "launch", args.simulator, BUNDLE, env=env, capture_output=True, text=True)
            match = re.search(r":\s*(\d+)\s*$", launched.stdout)
            if not match:
                raise RuntimeError("The native fixture did not report its process ID")
            pid = int(match.group(1))
            container = Path(
                run(
                    "xcrun",
                    "simctl",
                    "get_app_container",
                    args.simulator,
                    BUNDLE,
                    "data",
                    capture_output=True,
                    text=True,
                ).stdout.strip()
            )
            output = container / "Library/Application Support/generic-file-qualification"
            wait_for(lambda: (output / "queued").exists(), "native task submission")
            os.kill(pid, signal.SIGSTOP)
            stopped = True
            gate.set()
            wait_for(lambda: len(received) == len(expected) or failures, "uploads while the app process is stopped")
            if failures:
                raise RuntimeError(failures[0])
            os.kill(pid, signal.SIGCONT)
            stopped = False
            result_file = output / "result.json"
            wait_for(result_file.exists, "persistent native upload outcomes")
            result = json.loads(result_file.read_text())
            if result != {"completed": 3}:
                raise RuntimeError("Native upload completion failed: " + str(result))
            print(
                "Passed: PDF, EPUB and empty custom file; exact bytes/MIME; uploads continued with the app process stopped."
            )
        finally:
            gate.set()
            if stopped and pid is not None:
                os.kill(pid, signal.SIGCONT)
            subprocess.run(
                ["xcrun", "simctl", "terminate", args.simulator, BUNDLE],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=30,
            )
            server.shutdown()
            server.server_close()


if __name__ == "__main__":
    main()
