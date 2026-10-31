#!/usr/bin/env python3
"""Exercise production Swift social APIs with isolated accounts and real face inference."""

import argparse
import os
from pathlib import Path
import runpy
import shutil
import subprocess
import sys
import tempfile
import uuid

import ui_qualification

IOS = Path(__file__).resolve().parent
ROOT = IOS.parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--backend-stable", action="store_true")
    parser.add_argument("--simulator", help="Also render production views in a separate simulator-only test app.")
    args = parser.parse_args()
    if not args.backend_stable:
        parser.error("Confirm the disposable local backend is stable with --backend-stable.")
    sys.path.insert(0, str(ROOT / "scripts"))
    faces = runpy.run_path(str(ROOT / "scripts/faces-smoke.py"), run_name="social_fixture")
    account = faces["media"]["account"]
    workspace = None
    app = None
    if args.simulator:
        scratch = IOS / ".test-work"
        scratch.mkdir(exist_ok=True)
        workspace = Path(tempfile.mkdtemp(prefix="ui-qualification-", dir=scratch))
        try:
            app = ui_qualification.build(workspace)
        except BaseException:
            shutil.rmtree(workspace)
            raise
    try:
        return run_fixture(account, faces, app, args.simulator)
    finally:
        if workspace:
            shutil.rmtree(workspace)


def run_fixture(account, faces, app, simulator):
    with account() as (owner, subject, library, uploads), account() as (recipient, recipient_id, _, _):
        try:
            faces["smoke"].sql(
                """
                UPDATE principals SET display_name='UI fixture owner',discoverable=true WHERE subject=:'owner';
                UPDATE principals SET display_name='UI fixture recipient',discoverable=true WHERE subject=:'recipient';
                """,
                owner=subject,
                recipient=recipient_id,
            )
            assets = []
            for name in ("obama-2009", "biden-2013"):
                image = ROOT / "face-inference/fixtures/photos" / (name + ".jpg")
                if not image.exists():
                    raise RuntimeError("Generate the documented licensed face fixtures before this test.")
                assets.append(faces["upload"](owner, library, uploads, image.read_bytes(), name + ".jpg"))
            faces["automatic_jobs"](owner, assets)
            env = os.environ.copy()
            env.update(
                {
                    "NEPHOS_SOCIAL_E2E": "1",
                    "NEPHOS_E2E_BEARER": owner,
                    "NEPHOS_E2E_SUBJECT": subject,
                    "NEPHOS_E2E_RECIPIENT_BEARER": recipient,
                    "NEPHOS_E2E_RECIPIENT": recipient_id,
                    "NEPHOS_E2E_LIBRARY": library,
                    "NEPHOS_E2E_ASSETS": ",".join(asset["id"] for asset in assets),
                }
            )
            result = subprocess.run(
                ["swift", "test", "--scratch-path", ".build", "--filter", "NativeSocialTests"],
                cwd=IOS,
                env=env,
                text=True,
                capture_output=True,
                timeout=180,
                check=False,
            )
            output = result.stdout + result.stderr
            print(output.replace(owner, "[REDACTED]").replace(recipient, "[REDACTED]"), end="")
            if result.returncode == 0 and app:
                share_id = str(uuid.uuid4())
                faces["request"](
                    faces["API"] + "/v1/shares/" + share_id,
                    token=owner,
                    method="PUT",
                    data={
                        "libraryId": library,
                        "recipientId": recipient_id,
                        "allAssets": False,
                        "assetIds": [assets[0]["id"]],
                    },
                )
                try:
                    ui_qualification.capture(simulator, app, env)
                finally:
                    faces["request"](
                        faces["API"] + "/v1/shares/" + share_id, token=owner, method="DELETE", expected=204
                    )
            return result.returncode
        finally:
            faces["cleanup_faces"](subject)
            faces["cleanup_faces"](recipient_id)


if __name__ == "__main__":
    raise SystemExit(main())
