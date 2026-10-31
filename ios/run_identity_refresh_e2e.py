#!/usr/bin/env python3
"""Verify production Swift claim rules against a real, disposable Keycloak OIDC refresh."""

import os
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parent.parent
container = subprocess.check_output(["docker", "compose", "ps", "-q", "admin-console"], cwd=root, text=True).strip()
if not container:
    raise SystemExit("Start the local development administration stack before this check.")
workspace = root / "ios/.test-work"
workspace.mkdir(exist_ok=True)
with tempfile.TemporaryDirectory(prefix="identity-refresh-", dir=workspace) as directory:
    claims = Path(directory) / "claims.json"
    subprocess.run(
        [
            sys.executable,
            str(root / "scripts/admin-browser-smoke.py"),
            "--console-container",
            container,
            "--native-claims",
            str(claims),
        ],
        cwd=root,
        check=True,
    )
    subprocess.run(
        ["swift", "test", "--filter", "IdentityTokenTests/testRealKeycloakRefreshClaims"],
        cwd=root / "ios",
        check=True,
        env={**os.environ, "NEPHOS_IDENTITY_CLAIMS_FIXTURE": str(claims)},
    )
