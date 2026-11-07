#!/usr/bin/env python3
"""Append new development settings without rotating existing credentials."""

import os
import base64
from pathlib import Path
import secrets

path = Path(__file__).resolve().parents[1] / ".env"
existing = {line.split("=", 1)[0] for line in path.read_text().splitlines() if "=" in line}
with path.open("a") as output:
    for name in (
        "ADMIN_OIDC_CLIENT_SECRET",
        "ADMIN_SESSION_SECRET",
        "ADMIN_SESSION_STORE_PASSWORD",
        "SERVICE_KEY",
        "SERVER_ID",
        "ADMIN_SERVICE_KEY",
        "IDENTITY_ADMIN_SERVICE_KEY",
        "NEPHOS_PIN_PEPPER",
        "API_INTROSPECTION_CLIENT_SECRET",
        "BROKER_PUBLISHER_PASSWORD",
        "BROKER_PROJECTOR_PASSWORD",
    ):
        if name not in existing:
            output.write(f"{name}={secrets.token_hex(24)}\n")
    output.flush()
    if "NEPHOS_QR_DELIVERY_KEY" not in existing:
        output.write(f"NEPHOS_QR_DELIVERY_KEY={base64.b64encode(secrets.token_bytes(32)).decode()}\n")
    if "NEPHOS_QR_KEY_VERSION" not in existing:
        output.write("NEPHOS_QR_KEY_VERSION=1\n")
    output.flush()
    os.fsync(output.fileno())
os.chmod(path, 0o600)
print("Development settings upgraded; existing credentials unchanged.")
