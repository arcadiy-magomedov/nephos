#!/usr/bin/env python3
"""Generate local-only credentials without putting them in command output."""

import os
from pathlib import Path
import secrets

root = Path(__file__).resolve().parents[1]
path = root / ".env"
names = [
    "POSTGRES_PASSWORD",
    "LIBRARY_OWNER_PASSWORD",
    "LIBRARY_APP_PASSWORD",
    "STORAGE_OWNER_PASSWORD",
    "STORAGE_APP_PASSWORD",
    "KEYCLOAK_DB_PASSWORD",
    "KEYCLOAK_ADMIN_PASSWORD",
    "ADMIN_OIDC_CLIENT_SECRET",
    "ADMIN_SESSION_SECRET",
    "ADMIN_SESSION_STORE_PASSWORD",
    "RABBITMQ_PASSWORD",
    "GRAFANA_PASSWORD",
    "SERVICE_KEY",
    "SERVER_ID",
    "ADMIN_SERVICE_KEY",
    "IDENTITY_ADMIN_SERVICE_KEY",
    "NEPHOS_PIN_PEPPER",
    "API_INTROSPECTION_CLIENT_SECRET",
    "BROKER_PUBLISHER_PASSWORD",
    "BROKER_PROJECTOR_PASSWORD",
]
fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(fd, "w") as output:
    for name in names:
        output.write(f"{name}={secrets.token_hex(24)}\n")
print("Created ignored .env with owner-only permissions. Existing files are never overwritten.")
