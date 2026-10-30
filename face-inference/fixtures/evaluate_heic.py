"""Reproduce bounded HEIF face-inference evidence without publishing embeddings."""

import hashlib
import json
from pathlib import Path
import platform
import sys

import numpy as np
import pillow_heif

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root))
from infer import MODEL_VERSION, PREPROCESS_VERSION, analyze  # noqa: E402 -- Load the shared engine after the fixture's parent-directory bootstrap.

sources = json.loads((root / "fixtures/provenance.json").read_text())
generated = json.loads((root / "fixtures/heic/provenance.json").read_text())
originals, heics, fixtures = [], [], []
for source in sources:
    data = (root / "fixtures/heic" / (source["id"] + ".heic")).read_bytes()
    a = analyze((root / "fixtures/photos" / (source["id"] + ".jpg")).read_bytes())
    b = analyze(data)
    assert len(a["faces"]) == len(b["faces"]) == 1
    av, bv = a["faces"][0]["embedding"], b["faces"][0]["embedding"]
    assert av is not None and bv is not None
    similarity = float(np.dot(av, bv))
    assert similarity > 0.95
    assert hashlib.sha256(data).hexdigest() == b["sourceSha256"]
    originals.append(av)
    heics.append(bv)
    fixtures.append(
        {
            "id": source["id"],
            "sourceSha256": source["sha256"],
            "heicSha256": b["sourceSha256"],
            "bytes": len(data),
            "uprightDimensions": [b["width"], b["height"]],
            "detectedFaces": len(b["faces"]),
            "embeddingDimensions": len(bv),
            "jpegHeicSimilarity": round(similarity, 6),
            "maximumNormalizedBoxDelta": round(
                max(abs(a["faces"][0][key] - b["faces"][0][key]) for key in ("x", "y", "width", "height")), 6
            ),
        }
    )
same, different = [], []
for i, left in enumerate(sources):
    for j, right in enumerate(sources):
        if i == j:
            continue
        similarity = float(np.dot(originals[i], heics[j]))
        if left["label"] == right["label"]:
            same.append({"jpeg": left["id"], "heic": right["id"], "similarity": round(similarity, 6)})
            assert similarity > 0.45
        else:
            different.append(similarity)
assert max(different) < 0.45
orientation = []
baseline = analyze((root / "fixtures/heic/obama-2009-orientation-1.heic").read_bytes())
for value in range(2, 9):
    result = analyze((root / f"fixtures/heic/obama-2009-orientation-{value}.heic").read_bytes())
    similarity = float(np.dot(baseline["faces"][0]["embedding"], result["faces"][0]["embedding"]))
    assert similarity > 0.99
    orientation.append({"orientation": value, "similarityToUpright": round(similarity, 6)})
report = {
    "modelVersion": MODEL_VERSION,
    "preprocessVersion": PREPROCESS_VERSION,
    "runtime": {
        "platform": platform.platform(),
        "python": platform.python_version(),
        "pillowHeif": pillow_heif.__version__,
        "codecs": pillow_heif.libheif_info(),
    },
    "generatedFixtureCount": len(generated["fixtures"]),
    "generatedProvenance": "fixtures/heic/provenance.json (regenerated; binaries and manifest ignored)",
    "fixtures": fixtures,
    "differentPhotoSamePersonJpegHeicPairs": same,
    "crossPersonJpegHeicMaximum": round(max(different), 6),
    "orientation": orientation,
    "limitsUnchanged": {
        "bytes": 20971520,
        "pixels": 32000000,
        "faces": 64,
        "wallSeconds": 45,
        "cpuSeconds": 40,
        "addressSpaceBytes": 2147483648,
    },
    "limitations": [
        "Generated HEIC portraits are codec fixtures, NOT original camera captures.",
        "The separate public iPhone 12 Pro sample has no human faces; see fixtures/camera-source.json.",
        "No physical iPhone Photos permission/export/upload/restore round-trip was performed.",
        "No new ICC-to-sRGB transform, HDR tone mapping or gain-map application.",
        "No sequence, multiple top-level image, video or 48-megapixel support.",
        "These six publisher-labelled portraits do not establish population or family-photo accuracy.",
    ],
}
(root / "results").mkdir(exist_ok=True)
(root / "results/heic-inference.json").write_text(json.dumps(report, indent=2) + "\n")
print(json.dumps(report, indent=2))
