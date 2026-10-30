"""Download six freely licensed, publisher-labelled portraits; retain exact source hashes."""

import hashlib
import json
from pathlib import Path
import urllib.parse
import urllib.request
import urllib.error
import time

root = Path(__file__).resolve().parent
(root / "photos").mkdir(exist_ok=True)
sources = json.loads((root / "sources.json").read_text())
for source in sources:
    path = root / "photos" / (source["id"] + ".jpg")
    if not path.exists():
        request = urllib.request.Request(source["url"], headers={"User-Agent": "NephosTestFixtureResearch/1.0"})
        for attempt in range(4):
            try:
                with urllib.request.urlopen(request, timeout=60) as response:
                    data = response.read(20 * 1024 * 1024 + 1)
                break
            except urllib.error.HTTPError as error:
                if error.code not in (429, 503) or attempt == 3:
                    raise
                time.sleep(min(180, int(error.headers.get("Retry-After", "60"))))
        if len(data) > 20 * 1024 * 1024:
            raise RuntimeError("Fixture download exceeds 20 MiB")
        path.write_bytes(data)
        time.sleep(3)
    data = path.read_bytes()
    source["sourcePage"] = "https://commons.wikimedia.org/wiki/File:" + urllib.parse.quote(source["file"])
    source["sha256"] = hashlib.sha256(data).hexdigest()
    source["bytes"] = len(data)
    source["transformation"] = "None; exact downloaded originals are submitted to the pipeline."
    print(f"{source['id']}: {len(data)} bytes {source['sha256']}")
(root / "provenance.json").write_text(json.dumps(sources, indent=2) + "\n")
