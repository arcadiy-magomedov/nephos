#!/usr/bin/env python3
"""Create installation-local Penpot secrets without overwriting existing state."""

import json
import os
from pathlib import Path
import secrets


def main():
    root = Path(__file__).resolve().parent
    env = root / ".env"
    if not env.exists():
        with env.open("x") as output:
            os.chmod(env, 0o600)
            output.write("PENPOT_SECRET_KEY=" + secrets.token_urlsafe(64) + "\n")
            output.write("PENPOT_DATABASE_PASSWORD=" + secrets.token_hex(32) + "\n")
    credentials = root / ".credentials.json"
    if not credentials.exists():
        with credentials.open("x") as output:
            os.chmod(credentials, 0o600)
            json.dump(
                {"email": "designer@nephos.local", "password": secrets.token_urlsafe(32), "name": "Nephos Design"},
                output,
            )
    for directory in ("assets", "postgres"):
        (root / ".data" / directory).mkdir(parents=True, exist_ok=True)
    print("Local secrets ready. Start: docker compose --env-file .env -f compose.yaml up -d")


if __name__ == "__main__":
    main()
