"""Offline public-fixture experiment; never imports production inference or contacts a database."""

import argparse
import hashlib
import importlib.metadata
import importlib.util
import itertools
import json
import math
import os
from pathlib import Path
import platform
import random
import resource
import sys
import time
import urllib.request
import zipfile

for variable in ("OMP_NUM_THREADS", "OPENBLAS_NUM_THREADS", "MKL_NUM_THREADS", "VECLIB_MAXIMUM_THREADS"):
    os.environ[variable] = "1"
os.environ["HF_HUB_OFFLINE"] = "1"
os.environ["HF_HUB_DISABLE_TELEMETRY"] = "1"

ROOT = Path(__file__).resolve().parents[1]
THRESHOLDS = [round(i / 100, 2) for i in range(15, 86, 5)]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def verified(path, expected):
    if digest(path) != expected:
        raise ValueError(f"Checksum mismatch: {path.name}")
    return path


def quantiles(values):
    if not values:
        return {"count": 0, "min": None, "p50": None, "p95": None, "max": None}
    ordered = sorted(values)

    def percentile(p):
        position = (len(ordered) - 1) * p
        lower = math.floor(position)
        upper = math.ceil(position)
        return ordered[lower] + (ordered[upper] - ordered[lower]) * (position - lower)

    return {
        "count": len(values),
        "min": min(values),
        "p50": percentile(0.5),
        "p95": percentile(0.95),
        "max": max(values),
    }


def pair_counts(matrix, labels, threshold=None, clusters=None):
    merges = splits = same = different = 0
    for i, label in enumerate(labels):
        for j in range(i + 1, len(labels)):
            truth = label == labels[j]
            predicted = matrix[i][j] >= threshold if clusters is None else clusters[i] == clusters[j]
            same += int(truth)
            different += int(not truth)
            merges += int(predicted and not truth)
            splits += int(not predicted and truth)
    return {"same_pairs": same, "different_pairs": different, "false_merges": merges, "false_splits": splits}


def greedy(matrix, threshold, order, margin=0.05):
    """Current root-max/ambiguity semantics, without database caps or manual roots."""
    clusters = []
    result = [-1] * len(matrix)
    for i in order:
        scores = sorted(
            [(max(matrix[i][j] for j in members), c) for c, members in enumerate(clusters)],
            reverse=True,
        )
        scores = [(score, c) for score, c in scores if score >= threshold]
        if scores and (len(scores) == 1 or scores[1][0] < scores[0][0] - margin):
            cluster = scores[0][1]
        else:
            cluster = len(clusters)
            clusters.append([])
        clusters[cluster].append(i)
        result[i] = cluster
    return result


def constrained_graph(matrix, threshold, cannot_link=()):
    """Descending-edge union, rejecting every cross-cluster low-score or cannot-link edge."""
    clusters = [{i} for i in range(len(matrix))]
    excluded = {frozenset(pair) for pair in cannot_link}
    edges = sorted(
        [(matrix[i][j], i, j) for i in range(len(matrix)) for j in range(i + 1, len(matrix))],
        reverse=True,
    )
    for score, i, j in edges:
        if score < threshold:
            break
        left = next(c for c in clusters if i in c)
        right = next(c for c in clusters if j in c)
        if left is right:
            continue
        if all(matrix[a][b] >= threshold and frozenset((a, b)) not in excluded for a in left for b in right):
            left.update(right)
            clusters.remove(right)
    return [next(c for c, members in enumerate(clusters) if i in members) for i in range(len(matrix))]


def clustering_sweep(matrix, labels):
    n = len(labels)
    if n <= 6:
        orders = list(itertools.permutations(range(n)))
    else:
        rng = random.Random(20261101)
        orders = [tuple(range(n)), tuple(reversed(range(n)))]
        while len(orders) < 100:
            order = tuple(rng.sample(range(n), n))
            if order not in orders:
                orders.append(order)
    reports = []
    for threshold in THRESHOLDS:
        results = [pair_counts(matrix, labels, clusters=greedy(matrix, threshold, order)) for order in orders]
        graph = constrained_graph(matrix, threshold)
        reports.append(
            {
                "threshold": threshold,
                "pair_classification": pair_counts(matrix, labels, threshold=threshold),
                "greedy": {
                    "orders": len(orders),
                    "false_merges": quantiles([r["false_merges"] for r in results]),
                    "false_splits": quantiles([r["false_splits"] for r in results]),
                },
                "complete_link_constrained_graph": {
                    **pair_counts(matrix, labels, clusters=graph),
                    "clusters": len(set(graph)),
                    "cannot_links": 0,
                },
            }
        )
    return reports


def recognition_report(vectors, sources):
    import numpy as np

    matrix = np.clip(vectors @ vectors.T, -1, 1).astype(float).tolist()
    labels = [s["label"] for s in sources]
    pairs = [
        {
            "left": sources[i]["id"],
            "right": sources[j]["id"],
            "same_identity": labels[i] == labels[j],
            "cosine": matrix[i][j],
        }
        for i in range(len(labels))
        for j in range(i + 1, len(labels))
    ]
    return {
        "images": len(sources),
        "identities": len(set(labels)),
        "ids": [s["id"] for s in sources],
        "pairs": pairs,
        "same_identity_cosine": quantiles([p["cosine"] for p in pairs if p["same_identity"]]),
        "different_identity_cosine": quantiles([p["cosine"] for p in pairs if not p["same_identity"]]),
        "sweep": clustering_sweep(matrix, labels),
    }


def prepare(model_root, extra_root):
    """Only explicit public downloads; inference itself is offline."""
    resources = json.loads((ROOT / "scripts/face-benchmark-models.json").read_text())["resources"]
    for item in resources:
        target = model_root / item["file"]
        target.parent.mkdir(parents=True, exist_ok=True)
        if not target.exists():
            request = urllib.request.Request(item["url"], headers={"User-Agent": "NephosPublicBenchmark/1.0"})
            with urllib.request.urlopen(request, timeout=120) as response, target.open("wb") as output:
                while block := response.read(1024 * 1024):
                    output.write(block)
        verified(target, item["sha256"])
    archive = model_root / "buffalo_l.zip"
    with zipfile.ZipFile(archive) as bundle:
        target = model_root / "w600k_r50.onnx"
        if not target.exists():
            target.write_bytes(bundle.read("w600k_r50.onnx"))
    expected = json.loads((ROOT / "scripts/face-benchmark-models.json").read_text())["arcface_sha256"]
    verified(target, expected)
    extra_root.mkdir(parents=True, exist_ok=True)
    for source in json.loads((ROOT / "scripts/face-benchmark-fixtures.json").read_text()):
        target = extra_root / source["file"]
        if not target.exists():
            request = urllib.request.Request(source["url"], headers={"User-Agent": "NephosPublicBenchmark/1.0"})
            with urllib.request.urlopen(request, timeout=120) as response:
                target.write_bytes(response.read())
            time.sleep(2)
        verified(target, source["sha256"])


def load_model(name, fixture_root, model_root):
    import cv2
    import numpy as np

    manifest = json.loads((ROOT / "scripts/face-benchmark-models.json").read_text())
    if name == "sface":
        entry = json.loads((fixture_root / "models.json").read_text())["models"][1]
        path = verified(fixture_root / "models" / entry["file"], entry["sha256"])
        model = cv2.FaceRecognizerSF.create(str(path), "")

        def feature(crop):
            return model.feature(crop).flatten()
    elif name == "arcface":
        import onnx
        import onnxruntime as ort

        path = verified(model_root / "w600k_r50.onnx", manifest["arcface_sha256"])
        # Canonical ArcFaceONNX detects internal normalization from the first eight nodes.
        names = [node.name for node in onnx.load(path).graph.node[:8]]
        if any(n.startswith(("Sub", "_minus")) for n in names) and any(n.startswith(("Mul", "_mul")) for n in names):
            raise ValueError("This pinned checkpoint unexpectedly contains internal normalization")
        options = ort.SessionOptions()
        options.intra_op_num_threads = options.inter_op_num_threads = 1
        model = ort.InferenceSession(str(path), sess_options=options, providers=["CPUExecutionProvider"])
        input_name = model.get_inputs()[0].name
        assert model.get_inputs()[0].shape[1:] == [3, 112, 112]

        def feature(crop):
            return model.run(
                None,
                {input_name: cv2.dnn.blobFromImage(crop, 1 / 127.5, (112, 112), (127.5,) * 3, swapRB=True)},
            )[0].flatten()
    else:
        import torch
        from safetensors.torch import load_file

        torch.set_num_threads(1)
        torch.set_num_interop_threads(1)
        for entry in manifest["resources"]:
            if entry["file"].startswith("adaface/"):
                verified(model_root / entry["file"], entry["sha256"])
        path = model_root / "adaface/model.safetensors"
        spec = importlib.util.spec_from_file_location("cvl_ir101", model_root / "adaface/model.py")
        canonical = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(canonical)
        model = canonical.IR_101((112, 112))
        weights = load_file(str(path))
        model.load_state_dict({key.removeprefix("model.net."): value for key, value in weights.items()}, strict=True)
        model.eval()

        def feature(crop):
            rgb = np.ascontiguousarray(crop[:, :, ::-1].transpose(2, 0, 1))
            tensor = (torch.from_numpy(rgb).float() / 255 - 0.5) / 0.5
            with torch.inference_mode():
                return model(tensor.unsqueeze(0)).numpy().flatten()

    def normalized(crop):
        vector = feature(crop)
        norm = float(np.linalg.norm(vector))
        if not np.isfinite(vector).all() or norm <= 0:
            raise ValueError("Invalid embedding")
        return vector / norm

    return normalized, {"bytes": path.stat().st_size, "sha256": digest(path)}


def run(args):
    import cv2
    import numpy as np

    cv2.setNumThreads(1)
    cv2.ocl.setUseOpenCL(False)
    sys.path.insert(0, str(args.fixture_root))
    from decoder import decode_working_rgb

    manifest = json.loads((args.fixture_root / "models.json").read_text())
    detector_path = verified(
        args.fixture_root / "models" / manifest["models"][0]["file"], manifest["models"][0]["sha256"]
    )
    aligner_path = verified(
        args.fixture_root / "models" / manifest["models"][1]["file"], manifest["models"][1]["sha256"]
    )
    detector = cv2.FaceDetectorYN.create(str(detector_path), "", (320, 320), 0.9, 0.3, 5000)
    aligner = cv2.FaceRecognizerSF.create(str(aligner_path), "")

    def align(path):
        working, _ = decode_working_rgb(path.read_bytes())
        image = np.array(working)[:, :, ::-1].copy()
        working.close()
        height, width = image.shape[:2]
        scale = min(1.0, 1280 / max(width, height))
        small = cv2.resize(image, (round(width * scale), round(height * scale)))
        detector.setInputSize((small.shape[1], small.shape[0]))
        _, detections = detector.detect(small)
        if detections is None or len(detections) != 1:
            raise ValueError(f"Expected exactly one publisher-labelled subject: {path.name}")
        face = detections[0].copy()
        face[:14] /= scale
        if min(face[2:4]) < 48:
            raise ValueError(f"Face too small: {path.name}")
        # YuNet's eye/nose/mouth order and SFace's 112px ArcFace template are identical
        # to canonical InsightFace norm_crop. Keep production's exact float/warp behavior.
        return aligner.alignCrop(image, face)

    originals = json.loads((args.fixture_root / "fixtures/provenance.json").read_text())
    extras = json.loads((ROOT / "scripts/face-benchmark-fixtures.json").read_text())
    sources, crops, rejected = [], [], []
    for source in originals + extras:
        path = (
            args.fixture_root / "fixtures/photos" / (source["id"] + ".jpg")
            if source in originals
            else args.extra_root / source["file"]
        )
        verified(path, source["sha256"])
        try:
            crop = align(path)
        except ValueError as error:
            rejected.append({"id": source["id"], "reason": str(error)})
            continue
        sources.append(source)
        crops.append(crop)
    if any(source["id"] in {r["id"] for r in rejected} for source in originals):
        raise ValueError("The six baseline portraits must all remain usable")

    pipeline_ms = []
    for _ in range(3):
        for source in originals:
            start = time.perf_counter()
            align(args.fixture_root / "fixtures/photos" / (source["id"] + ".jpg"))
            pipeline_ms.append(1000 * (time.perf_counter() - start))
    peak_before_model = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    started = time.perf_counter()
    embed, checkpoint = load_model(args.model, args.fixture_root, args.model_root)
    load_ms = 1000 * (time.perf_counter() - started)
    for _ in range(3):
        for crop in crops:
            embed(crop)
    vectors = np.stack([embed(crop) for crop in crops])
    timings = []
    for _ in range(args.rounds):
        for crop in crops:
            start = time.perf_counter()
            embed(crop)
            timings.append(1000 * (time.perf_counter() - start))
    invariance = []
    generated = json.loads((args.fixture_root / "fixtures/heic/provenance.json").read_text())
    variants = generated["fixtures"]
    lookup = {s["id"]: i for i, s in enumerate(sources)}
    for variant in variants:
        path = verified(args.fixture_root / variant["path"], variant["sha256"])
        source_id = variant["sourceId"]
        if source_id not in {source["id"] for source in originals}:
            raise ValueError("HEIC provenance must refer to a verified public baseline photo")
        try:
            crop = align(path)
            cosine = float(vectors[lookup[source_id]] @ embed(crop))
            invariance.append({"file": path.name, "source": source_id, "cosine": cosine, "status": "ok"})
        except ValueError as error:
            invariance.append({"file": path.name, "status": "rejected", "reason": str(error)})
    robustness = []
    for source, crop, vector in zip(sources, crops, vectors):
        ok, jpeg = cv2.imencode(".jpg", crop, [cv2.IMWRITE_JPEG_QUALITY, 30])
        assert ok
        occluded = crop.copy()
        occluded[82:, :] = 0
        transformed = {
            "jpeg_quality30": cv2.imdecode(jpeg, cv2.IMREAD_COLOR),
            "blur_sigma1.2": cv2.GaussianBlur(crop, (0, 0), 1.2),
            "downsample56": cv2.resize(cv2.resize(crop, (56, 56)), (112, 112)),
            "brightness_half": (crop.astype(float) * 0.5).astype(np.uint8),
            "bottom30_black": occluded,
        }
        for name, image in transformed.items():
            robustness.append({"source": source["id"], "transformation": name, "cosine": float(vector @ embed(image))})
    peak = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    rss_unit = 1 if sys.platform == "darwin" else 1024
    report = {
        "schema": 1,
        "model": args.model,
        "checkpoint": checkpoint,
        "runtime": {
            "platform": platform.platform(),
            "machine": platform.machine(),
            "processor": platform.processor(),
            "python": platform.python_version(),
            "threads": 1,
            "provider": "CPU only; no MPS/CoreML/CUDA",
            "versions": {
                package: importlib.metadata.version(package)
                for package in ("numpy", "opencv-python-headless", "Pillow", "pillow-heif", "torch", "onnxruntime")
            },
        },
        "alignment": {
            "contract": "production decode/YuNet max1280 score0.9; SFace alignCrop ArcFace-template BGR112x112",
            "crop_sha256": {
                source["id"]: hashlib.sha256(crop.tobytes()).hexdigest() for source, crop in zip(sources, crops)
            },
            "decoder_sha256": digest(args.fixture_root / "decoder.py"),
            "yunet_sha256": digest(detector_path),
            "heic_provenance_sha256": digest(args.fixture_root / "fixtures/heic/provenance.json"),
        },
        "latency": {
            "load_ms": load_ms,
            "feature_warmed_ms": quantiles(timings),
            "feature_warmup_passes": 3,
            "decode_detect_align_warmed_ms": quantiles(pipeline_ms),
            "pipeline_note": "6 original JPEGs, 3 passes after initial fixture loading; excludes model load/hash/feature",
            "memory_peak_process_bytes": peak * rss_unit,
            "memory_peak_before_candidate_load_bytes": peak_before_model * rss_unit,
            "memory_note": "Isolated-process high-water RSS, including imports, detector/SFace aligner, decode and crops",
        },
        "base_six": recognition_report(vectors[: len(originals)], sources[: len(originals)]),
        "expanded": recognition_report(vectors, sources),
        "rejected_originals": rejected,
        "codec_variants": invariance,
        "same_crop_transformations": robustness,
        "transformation_cosine": {
            name: quantiles([r["cosine"] for r in robustness if r["transformation"] == name])
            for name in sorted({r["transformation"] for r in robustness})
        },
        "limitations": [
            "Only public publisher-labelled adult male US politicians; not population, child or family evidence.",
            "Three original genuine pairs; expanded pairs and thresholds are exploratory, not a held-out calibration.",
            "Codec/crop transformations are correlated with their source and never added to independent pair counts.",
            "Constrained graph uses complete-link gating; no real co-occurrence/manual cannot-links in these portraits.",
            "Greedy models root-max and 0.05 ambiguity, not SQL representative caps or manual merge/exclusion state.",
            "No private media, database, live clustering, training or production inference change.",
            "CPU timings are on this shared Mac, not the deployment home-server or a universal backbone comparison.",
            "ViT KP-RPE not run: bounded three-embedding-model experiment selects requested IR101 candidate.",
        ],
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2, allow_nan=False) + "\n")
    print(json.dumps({"model": args.model, "images": len(sources), "rejected": rejected, "latency": report["latency"]}))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixture-root", type=Path, default=ROOT / "face-inference")
    parser.add_argument("--model-root", type=Path, default=ROOT / "artifacts/face-benchmark-models")
    parser.add_argument("--extra-root", type=Path, default=ROOT / "artifacts/face-benchmark-fixtures")
    parser.add_argument("--prepare", action="store_true")
    parser.add_argument("--model", choices=("sface", "arcface", "adaface"))
    parser.add_argument("--rounds", type=int, default=20)
    parser.add_argument("--output", type=Path, default=ROOT / "artifacts/face-benchmark-result.json")
    args = parser.parse_args()
    if args.prepare:
        prepare(args.model_root, args.extra_root)
    if args.model:
        if args.rounds < 2:
            parser.error("--rounds must be at least 2")
        run(args)
    elif not args.prepare:
        parser.error("Choose --prepare or --model")


if __name__ == "__main__":
    main()
