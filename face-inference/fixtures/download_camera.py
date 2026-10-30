"""Download one explicitly permitted public camera fixture; never redistribute it."""

import hashlib
import json
from pathlib import Path
import urllib.request

root = Path(__file__).resolve().parent
source = json.loads((root / "camera-source.json").read_text())
path = root / "camera" / source["filename"]
if path.exists():
    data = path.read_bytes()
else:
    request = urllib.request.Request(source["url"], headers={"User-Agent": "NephosTestFixtureResearch/1.0"})
    with urllib.request.urlopen(request, timeout=60) as response:
        data = response.read(source["bytes"] + 1)
if len(data) != source["bytes"] or hashlib.sha256(data).hexdigest() != source["sha256"]:
    raise RuntimeError("Camera fixture checksum mismatch")
path.parent.mkdir(exist_ok=True)
path.write_bytes(data)
print(f"{source['id']}: {len(data)} bytes, SHA-256 verified; test-use permission only.")
