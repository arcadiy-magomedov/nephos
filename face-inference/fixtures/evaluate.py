"""Actual YuNet/SFace evaluation. Labels come exclusively from source metadata."""

import json
from pathlib import Path
import sys
import time
import numpy as np

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root))
from infer import analyze  # noqa: E402 -- Load the shared engine after the fixture's parent-directory bootstrap.

sources = json.loads((root / "fixtures/provenance.json").read_text())
results = []
vectors = []
for source in sources:
    start = time.monotonic()
    result = analyze((root / "fixtures/photos" / (source["id"] + ".jpg")).read_bytes())
    elapsed = time.monotonic() - start
    usable = [face for face in result["faces"] if face["embedding"] is not None]
    # Portrait fixtures have one publisher-labelled subject; ambiguity is reported, not silently labelled.
    vector = np.array(usable[0]["embedding"]) if len(usable) == 1 else None
    vectors.append(vector)
    results.append(
        {
            "id": source["id"],
            "publisherLabel": source["label"],
            "detections": len(result["faces"]),
            "usable": len(usable),
            "seconds": round(elapsed, 3),
            "result": result,
        }
    )
matrix = [
    [round(float(np.dot(a, b)), 6) if a is not None and b is not None else None for b in vectors] for a in vectors
]
same, different = [], []
for i, left in enumerate(sources):
    for j in range(i + 1, len(sources)):
        pair = {"left": left["id"], "right": sources[j]["id"], "similarity": matrix[i][j]}
        (same if left["label"] == sources[j]["label"] else different).append(pair)
report = {
    "threshold": 0.45,
    "ambiguityMargin": 0.05,
    "source": "publisher metadata; not inferred image identities",
    "fixtures": results,
    "similarityMatrix": matrix,
    "samePersonPairs": same,
    "differentPersonPairs": different,
    "falsePairSplits": [p for p in same if p["similarity"] is None or p["similarity"] < 0.45],
    "falsePairMerges": [p for p in different if p["similarity"] is not None and p["similarity"] >= 0.45],
}
(root / "results").mkdir(exist_ok=True)
(root / "results/real-inference.json").write_text(json.dumps(report, indent=2) + "\n")
print(json.dumps({k: v for k, v in report.items() if k != "fixtures"}, indent=2))
