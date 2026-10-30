#!/usr/bin/env python3
"""Run opt-in native Swift networking XCTest with an ephemeral real-server fixture."""

import argparse
import os
from pathlib import Path
import runpy
import shutil
import subprocess
import sys
import uuid

IOS = Path(__file__).resolve().parent
ROOT = IOS.parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--backend-stable",
        action="store_true",
        help="Explicit confirmation that the disposable local backend is stable for network tests.",
    )
    args = parser.parse_args()
    if not args.backend_stable:
        parser.error("No network operations started. Wait for backend stability, then pass --backend-stable.")

    sys.path.insert(0, str(ROOT / "scripts"))
    fixture = runpy.run_path(str(ROOT / "scripts" / "media-smoke.py"), run_name="native_e2e_fixture")
    workspace = IOS / ".test-work" / ("native-e2e-" + uuid.uuid4().hex)
    workspace.mkdir(parents=True)
    result_code = 1
    try:
        with fixture["account"]() as (token, subject, library, uploads):
            upload = str(uuid.uuid4())
            # Register the ID before Swift runs, including assertion/timeout failure cleanup.
            uploads.append(upload)
            resource_uploads = [str(uuid.uuid4()) for _ in range(4)]
            uploads.extend(resource_uploads)
            environment = os.environ.copy()
            environment.update(
                {
                    "NEPHOS_NATIVE_E2E": "1",
                    "NEPHOS_E2E_SERVER": fixture["API"],
                    "NEPHOS_E2E_BEARER": token,
                    "NEPHOS_E2E_SUBJECT": subject,
                    "NEPHOS_E2E_LIBRARY": library,
                    "NEPHOS_E2E_UPLOAD": upload,
                    "NEPHOS_E2E_RESOURCE_UPLOADS": ",".join(resource_uploads),
                    "NEPHOS_E2E_WORKSPACE": str(workspace),
                    "NEPHOS_E2E_REQUIRE_RETENTION": "1",
                }
            )
            try:
                result = subprocess.run(
                    [
                        "swift",
                        "test",
                        "--scratch-path",
                        ".build",
                        "--filter",
                        "NativeBackendTests/testRealBackendUploadResumeGalleryOriginalAndRetention",
                    ],
                    cwd=IOS,
                    env=environment,
                    text=True,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                    timeout=300,
                    check=False,
                )
                # Token is environment-only; defensively redact any unexpected framework diagnostics.
                print(result.stdout.replace(token, "[REDACTED]"), end="")
                result_code = result.returncode
            except subprocess.TimeoutExpired:
                print("Native E2E exceeded the five-minute runner limit; fixture cleanup will run.", file=sys.stderr)
            finally:
                environment.pop("NEPHOS_E2E_BEARER", None)
        print("Native E2E fixture account, registered asset, SQL state and media cleaned up.")
    finally:
        shutil.rmtree(workspace)
        parent = workspace.parent
        if parent.exists() and not any(parent.iterdir()):
            parent.rmdir()
    return result_code


if __name__ == "__main__":
    raise SystemExit(main())
