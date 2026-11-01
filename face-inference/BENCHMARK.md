# Offline face-model and clustering experiment

This is a **non-commercial research experiment**, not a production model migration.
No private gallery, database, people roots, Olivia embeddings or live jobs are read or modified.
Only checksum-verified public publisher-labelled fixture images are processed. Downloading
public models/photos is the only network activity; inference runs locally.

## Reproduce

Use a separate environment (Python 3.10 on the measured arm64 Mac; dependency versions
are recorded in each output). Do not replace the production dependency manifest:

```sh
python3 -m venv artifacts/face-benchmark-venv
artifacts/face-benchmark-venv/bin/python -m pip install -r scripts/face-benchmark-requirements.txt
python3 face-inference/download_models.py
python3 face-inference/fixtures/download.py
artifacts/face-benchmark-venv/bin/python face-inference/fixtures/generate_heic.py
artifacts/face-benchmark-venv/bin/python scripts/face_benchmark.py --prepare
for model in sface arcface adaface; do
  artifacts/face-benchmark-venv/bin/python scripts/face_benchmark.py \
    --model "$model" --output "artifacts/face-benchmark-$model.json"
done
python3 -m unittest discover -s scripts -p test_face_benchmark.py
```

Explicit `--fixture-root`, `--model-root`, and `--extra-root` allow reusing an existing
verified public fixture/model directory from an isolated worktree. **Run each model in a
fresh process**, serially, with 1 CPU thread. No GPU/CoreML/MPS providers or training.
`--rounds` defaults to 20 timed passes after three warmups; hashes/model creation are excluded
from warmed feature latency. Decode/detection/alignment is reported separately.
Downloads may be rate-limited; rerun preparation after waiting. Partial downloaded files
are never accepted if their hashes do not match (remove that individual partial file first).

## Contracts and scope

- Same production decoder and YuNet landmarks for all three backbones, score 0.9,
  detector maximum side 1280, one usable face per publisher-labelled original.
- Identical `FaceRecognizerSF.alignCrop` BGR 112×112 crops for all models.
  OpenCV 4.12's five-point template exactly matches InsightFace's ArcFace template:
  `(38.2946,51.6963), (73.5318,51.5014), (56.0252,71.7366),
  (41.5493,92.3655), (70.7299,92.2041)`. Preserve OpenCV's production float/warp
  implementation rather than introducing a different detector/alignment confound.
- SFace uses canonical OpenCV `feature`: RGB swap internally, raw 0–255 float input;
  its ONNX incorporates normalization. ArcFace `w600k_r50.onnx` uses canonical
  InsightFace `(RGB-127.5)/127.5`; inspected first eight graph nodes have no internal
  Sub/Mul normalization. AdaFace IR101 uses CVLFace's RGB `ToTensor` and mean/std 0.5,
  not legacy AdaFace's BGR advice; pinned `model.yaml` declares `color_space: RGB`.
  All embeddings are L2-normalized before cosine comparison, without test-time flipping.
- AdaFace uses the official inspected, SHA-pinned IR101 architecture, loaded from
  safetensors with **strict** `model.net.` prefix removal. No unreviewed
  `trust_remote_code`, pickle weights, training dependencies or mutable model revisions.
- Original six images remain a separate baseline (3 identities, 3 genuine/12 impostor
  pairs). Additional original images are documented in `scripts/face-benchmark-fixtures.json`.
  Rejected small/ambiguous detections are disclosed, never silently labelled.
- JPEG↔HEIC, eight orientations, synthetic 48MP, 10-bit/grid and multiple-image container
  fixtures are checked separately. Regenerated HEIC hashes may differ by encoder version;
  the exact local generated manifest hash is recorded. These are not original iPhone photos.
- Five post-alignment crop perturbations (JPEG30, blur, 56px, half brightness, lower
  30px black occlusion) measure same-photo robustness, **not independent identities**,
  real pose, camera behavior or recognition rates.
- Cosine threshold sweep 0.15–0.85 in 0.05 steps reports all false pair merges/splits.
  Existing greedy root-maximum matching with threshold 0.45 and ambiguity margin 0.05
  is compared with a descending-edge complete-link constrained graph. No single-link
  transitive bridge is permitted; all cross-member scores must pass. Manual cannot-links
  are unit-tested but absent from the real portrait corpus.
- Greedy order sensitivity: all 720 orders for the baseline six and 100 seeded unique
  orders for the expanded corpus. Not a SQL repository replica: representative/query
  caps and manual/exclusion state are not represented. No batch reclustering is added.
- RSS is isolated-process peak memory, **not** just weight memory; includes decoder,
  imports and existing SFace aligner. Mac CPU/backend results are not home-server latency.

## Licenses and checkpoint sources

Production YuNet/SFace retain their existing MIT/Apache-2.0 manifests and notices.
For candidate downloads see `scripts/face-benchmark-models.json` (exact URLs/revisions/SHA-256).
Do not redistribute candidate weights in this repository.

- [InsightFace v0.7 README](https://github.com/deepinsight/insightface/blob/v0.7/python-package/README.md):
  code MIT, **pretrained weights non-commercial research only**. This experiment uses the
  official `buffalo_l.zip` release's ArcFace ResNet50/WebFace600K `w600k_r50.onnx`, not
  the pack's RetinaFace detector, gender/age or other models. Ordinary product deployment
  is not cleared by the code license.
- [CVLFace MIT code license](https://github.com/mk-minchul/CVLface/blob/308142aa50adf2e187711354f7524635d3414f1e/LICENSE)
  and [official IR101 model card](https://huggingface.co/minchul/cvlface_adaface_ir101_webface12m/blob/54f602a0737bd1ee4a4e7e9fd089a485f397fefd/README.md):
  card says to **follow the training dataset license**, and does not grant an unrestricted
  weight/deployment license. WebFace12M is research data; its complete official agreement
  was not retrievable from `face-benchmark.org` during this experiment. No dataset is
  downloaded; this bounded public-weight evaluation is research only. Deployment and
  redistribution rights remain unresolved and require maintainer/dataset clarification.
- [ViT KP-RPE card](https://huggingface.co/minchul/cvlface_adaface_vit_base_kprpe_webface12m):
  not tested here. The requested IR101 option was runnable and satisfies the bounded three-model
  experiment. KP-RPE additionally requires the canonical normalized keypoint/aligner
  contract; no claim is made about its performance or licensing clearance.
- Additional photos are public-domain images per their Wikimedia publisher metadata,
  with source pages, attribution, dates and exact hashes retained. The existing Obama
  2009 CC BY 3.0 fixture keeps its original provenance/attribution.

This deliberately small, adult-male-politician-biased corpus cannot establish population,
children, family-age progression, lookalike, demographic fairness or open-set false-match
rates. Thresholds are not calibrated on a held-out set.

## Measured results (2026-11-01)

**Decision: retain YuNet + SFace and the existing conservative greedy policy.**
**Provisional research challenger: CVLFace AdaFace IR101**, not a deployment recommendation.
It offered the largest observed genuine/impostor separation and stronger blur/brightness
invariance here, but did not improve recognition errors at a suitable threshold, was
6.4× slower than SFace on this CPU stack, and has unresolved weight/deployment rights.
InsightFace ArcFace was 8.9× slower than SFace on this CPU stack and also requires separate
weight-use permission. These relative timings compare actual runtime implementations
(OpenCV, ONNX Runtime, PyTorch), not perfectly controlled backbone compute.

The experiment attempted **14 original photos** (the existing 6 + 8 public-domain additions).
**10 were usable, representing 6 identities: 4 genuine and 41 impostor pairs.**
Bush's independently dated 2001/2003 portraits provide the fourth genuine pair; Clinton
and Carter each contribute only one usable portrait. Rejections were consistent across
all three models:

- `clinton-1993`: YuNet did not return exactly one face at the unchanged 0.9 threshold.
- `carter-1971`: 30,425,995 bytes exceeds the production 20MiB payload limit
  (the source is also an enormous 795MP scan; it was not decoded or limits overridden).
- `obama-2010-speech`: face smaller than the production 48px usability gate.
- `biden-2023-speech`: multiple/ambiguous detections, not silently labelled as Biden.
- A ninth proposed addition, Trump's 2019 UN speech, was abandoned after Wikimedia
  HTTP 429 with bounded backoff; no rate-limit bypass or unlicensed substitute.

The age/date-separated Obama 2009/2012, Biden 2013/2021, Trump 2017/2025 and Bush
2001/2003 photos are real different-photo pairs, not synthetic rotations. The usable
photos are predominantly frontal portraits; **the attempted speech/pose cases were
not usable, so this does not establish challenging-pose accuracy**. Detection failure is
a separate end-to-end limitation shared by all three backbones in this controlled setup.

Measured on macOS arm64, CPU only, one thread; **200 timed feature calls/model**:

| Model/checkpoint | Genuine cosine min / median | Impostor cosine median / max | False merges / splits at 0.45 | Warm feature p50 / p95, ms | Weight MiB | Peak process RSS MiB |
| --- | --- | --- | --- | --- | --- | --- |
| YuNet + SFace 2021dec | 0.524939 / 0.646720 | 0.108259 / 0.396453 | 0 / 0 | 17.35 / 19.27 | 36.90 | 1449.48 |
| InsightFace ArcFace `w600k_r50` | 0.449607 / 0.681569 | 0.005079 / 0.197130 | 0 / 1 | 155.11 / 161.88 | 166.31 | 1539.17 |
| CVLFace AdaFace IR101 WebFace12M | 0.511853 / 0.693891 | -0.008523 / 0.153863 | 0 / 0 | 110.52 / 124.83 | 248.89 | 1888.27 |

This is not evidence that 0.45 transfers across embedding spaces. ArcFace's split is
Trump 2017/2025 at **0.449607**. All three can produce zero observed pair errors on this
tiny corpus with different thresholds. Observed zero-error sweep points:

- SFace: **0.40, 0.45, 0.50**.
- ArcFace: **0.20–0.40** in 0.05 steps.
- AdaFace: **0.20–0.50** in 0.05 steps.

**Do not tune production to these sweep points**: the same photos were used both to
explore thresholds and report errors, with only four genuine pairs. Raw cosine margins
are also not directly calibrated across models.

Shared warmed JPEG decode + YuNet detection + alignment, excluding feature calls:
SFace process p50/p95 **172.76/210.59ms**, ArcFace process **166.51/206.05ms**,
AdaFace process **174.17/210.98ms** (18 calls each, shared-host variability).
Candidate initialization including imports/checksums/loading was **70.75ms / 1278.55ms /
2114.35ms**, respectively. RSS is a high-water mark of the entire process, including
large public-photo decodes and the shared detector/SFace alignment model; it cannot be
interpreted as candidate-only memory or a production-container capacity estimate.

### Codec and crop robustness (correlated variants, not extra recognition pairs)

All three accepted **17 generated HEIC fixtures** and rejected the multiple-image
container (`animated_image`). Same-photo JPEG↔HEIC cosine minima for the six normal
HEIC counterparts: **0.963450 / 0.970254 / 0.969284** (SFace/ArcFace/AdaFace).
Minima over all accepted generated variants including orientation, 48MP, grid and
10-bit: **0.962089 / 0.962306 / 0.969284**. Eight orientations were compared against
their source JPEG, so these values include downsampling/re-encoding, not just orientation.
The 48MP case is synthetic upscaling, not proof of real-camera detail preservation.

Worst same-crop cosine across the ten originals:

| Transformation | SFace | ArcFace | AdaFace IR101 |
| --- | --- | --- | --- |
| Gaussian blur σ1.2 | 0.906354 | 0.904335 | 0.952631 |
| Lower 30px black occlusion | 0.885625 | 0.811409 | 0.836991 |
| Half brightness | 0.963860 | 0.980187 | 0.994248 |
| Downsample to 56px then 112px | 0.938821 | 0.915839 | 0.936647 |
| JPEG quality 30 | 0.883173 | 0.902177 | 0.894071 |

AdaFace was better for this blur/brightness probe, while SFace was better for this
occlusion probe. These same-photo scores are not false-match/false-non-match rates.

### Clustering decision

At 0.45, greedy (all 720 baseline orders and 100 seeded expanded orders) and the
complete-link graph had identical error counts: SFace/AdaFace **0 merges, 0 splits,
6 expanded clusters**; ArcFace **0 merges, 1 split, 7 clusters**. No measured reason to
replace greedy in production. At the intentionally too-low SFace threshold 0.20,
greedy yielded **0–24 false merged pairs** depending on order while complete-link
yielded **0**; this is an exploratory illustration of bridge prevention, not a
validated recommendation to lower the threshold or auto-merge roots.

The Olivia fragmentation report is consistent with the existing online ambiguity
policy: near competing roots within 0.05 create another group; historical groups
are not batch-reclustered. This experiment **does not diagnose or solve Olivia's
private-photo case**. Preserve manual root-constrained merges/exclusions; neither
training nor live automatic reclustering was performed.

### Evidence and validation

Committed aggregate outputs (cosines and metadata, **no embeddings/images/weights**):
[SFace](benchmarks/sface.json), [ArcFace](benchmarks/arcface.json),
[AdaFace](benchmarks/adaface.json). Each records exact checkpoint SHA-256, package
versions, common crop hashes, original/variant rejections, every pair and all sweep points.
All three sets of aligned crop hashes match. Original public provenance and additional
source attribution are retained in their manifests; generated binary artifacts remain ignored.

- Six benchmark unit/consistency tests passed, including independent recomputation of
  all threshold error counts from the committed pair lists, cross-model crop equality,
  percentile interpolation, ambiguity behavior and constrained bridge/cannot-link gating.
- Direct comparison with production `infer.analyze` on all six original JPEGs reproduced
  SFace's entire pair matrix within **2.75×10⁻⁷** absolute cosine error.
- Direct strict loading of the official CVLFace IR101 safetensors checkpoint matched
  every architecture tensor and produced a finite 512-dimensional CPU embedding.
- Relevant Ruff check and format check passed. CI runs the lightweight math/report
  tests through existing script test discovery; restricted candidate weights are not
  downloaded by CI.

**Final rank is not established**: four genuine pairs and six politician identities,
correlated impostor comparisons, failed speech cases and no children/family/lookalike
or held-out data are insufficient to prove a general recognition winner. The simplest
justified choice today is retaining the licensed, fast working baseline; AdaFace IR101
is only the provisional candidate if a later locally consented, diverse evaluation and
license clarification justify further work.
