"""Create only optional faces credentials; never modify the platform .env."""

from pathlib import Path
import os
import secrets

destination = Path(".env.faces")
legacy = Path("deploy/faces/.env")
if legacy.exists() and not destination.exists():
    legacy.rename(destination)
if destination.exists():
    print("Existing .env.faces preserved.")
else:
    fd = os.open(destination, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    with os.fdopen(fd, "w") as stream:
        for name in ("FACES_POSTGRES_PASSWORD", "FACES_OWNER_PASSWORD", "FACES_APP_PASSWORD", "FACES_INFERENCE_KEY"):
            stream.write(f"{name}={secrets.token_hex(32)}\n")
    print("Created private optional face-service credentials.")
