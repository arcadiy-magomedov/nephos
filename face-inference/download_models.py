"""Fetch pinned, checksummed model weights and their directory-specific licenses."""

import hashlib
import json
from pathlib import Path
import urllib.request

root = Path(__file__).resolve().parent
manifest = json.loads((root / "models.json").read_text())
(root / "models").mkdir(exist_ok=True)
(root / "licenses").mkdir(exist_ok=True)
for model in manifest["models"]:
    destination = root / "models" / model["file"]
    if not destination.exists() or hashlib.sha256(destination.read_bytes()).hexdigest() != model["sha256"]:
        url = f"https://media.githubusercontent.com/media/opencv/opencv_zoo/{manifest['revision']}/models/{model['directory']}/{model['file']}"
        with urllib.request.urlopen(url, timeout=90) as response:
            data = response.read(model["bytes"] + 1)
        if len(data) != model["bytes"] or hashlib.sha256(data).hexdigest() != model["sha256"]:
            raise RuntimeError("Model length/checksum mismatch")
        destination.write_bytes(data)
    for name in ("LICENSE", "README.md"):
        url = f"https://raw.githubusercontent.com/opencv/opencv_zoo/{manifest['revision']}/models/{model['directory']}/{name}"
        with urllib.request.urlopen(url, timeout=30) as response:
            data = response.read(50000)
        (root / "licenses" / f"{model['directory']}-{name}").write_bytes(data)
    print(f"{model['file']}: verified {model['sha256']} ({model['license']})")
