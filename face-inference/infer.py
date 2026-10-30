"""Private CPU inference. No URLs, filenames, or network access from media input."""

import hashlib
import json
import os
from pathlib import Path
import sys

os.environ.setdefault("OPENBLAS_NUM_THREADS", "1")
os.environ.setdefault("OMP_NUM_THREADS", "1")
import cv2
import numpy as np
from decoder import ImageRejected, MAX_BYTES, decode_rgb

MODEL_VERSION = "yunet-2023mar-sface-2021dec-8f2383e4-0ba9fbfa"
PREPROCESS_VERSION = "exif-rgb-max1280-align5-v1"
cv2.setNumThreads(1)
cv2.ocl.setUseOpenCL(False)


def analyze(data):
    if not data or len(data) > MAX_BYTES:
        raise ImageRejected("payload_limit")
    root = Path(__file__).resolve().parent
    manifest = json.loads((root / "models.json").read_text())
    for model in manifest["models"]:
        if hashlib.sha256((root / "models" / model["file"]).read_bytes()).hexdigest() != model["sha256"]:
            raise RuntimeError("model_integrity")
    image = np.array(decode_rgb(data))[:, :, ::-1].copy()
    height, width = image.shape[:2]
    scale = min(1.0, 1280 / max(width, height))
    small = cv2.resize(image, (round(width * scale), round(height * scale)))
    detector = cv2.FaceDetectorYN.create(
        str(root / "models" / manifest["models"][0]["file"]), "", (small.shape[1], small.shape[0]), 0.9, 0.3, 5000
    )
    recognizer = cv2.FaceRecognizerSF.create(str(root / "models" / manifest["models"][1]["file"]), "")
    _, detections = detector.detect(small)
    faces = []
    if detections is not None:
        if len(detections) > 64:
            raise ValueError("face_count_limit")
        for detection in sorted(detections, key=lambda x: (float(x[0]), float(x[1]))):
            detection[:14] /= scale
            x, y, w, h = [float(v) for v in detection[:4]]
            left, top = max(0.0, x), max(0.0, y)
            right, bottom = min(float(width), x + w), min(float(height), y + h)
            if right <= left or bottom <= top:
                continue
            usable = min(w, h) >= 48
            embedding = None
            if usable:
                aligned = recognizer.alignCrop(image, detection)
                vector = recognizer.feature(aligned).flatten()
                norm = float(np.linalg.norm(vector))
                if not np.isfinite(vector).all() or norm <= 0:
                    raise ValueError("invalid_embedding")
                embedding = (vector / norm).tolist()
            faces.append(
                {
                    "x": left / width,
                    "y": top / height,
                    "width": (right - left) / width,
                    "height": (bottom - top) / height,
                    "confidence": float(detection[-1]),
                    "quality": "usable" if usable else "too_small",
                    "embedding": embedding,
                }
            )
    return {
        "modelVersion": MODEL_VERSION,
        "preprocessVersion": PREPROCESS_VERSION,
        "sourceSha256": hashlib.sha256(data).hexdigest(),
        "width": width,
        "height": height,
        "coordinateSpace": "exif-normalized",
        "faces": faces,
    }


if __name__ == "__main__":
    try:
        if sys.platform == "linux":
            import resource

            resource.setrlimit(resource.RLIMIT_CPU, (40, 40))
            resource.setrlimit(resource.RLIMIT_AS, (2 * 1024**3, 2 * 1024**3))
        print(json.dumps(analyze(sys.stdin.buffer.read(MAX_BYTES + 1)), allow_nan=False))
    except ImageRejected as error:
        print(json.dumps({"error": str(error)}))
        sys.exit(1)
    except Exception:
        print('{"error":"inference_rejected"}')
        sys.exit(1)
