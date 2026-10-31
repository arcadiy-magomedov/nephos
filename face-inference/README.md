# Optional owner-private face service

This is an independently deployable ASP.NET Core/.NET 10 API/worker with explicit
Npgsql repositories, its own PostgreSQL database, and a private CPU inference
container. It does **not** make the entire platform complete.

## What runs

* Actual YuNet detection, five-landmark alignment and SFace 128-dimensional,
  normalized face embeddings; no external inference API.
* Durable PostgreSQL jobs with unique `(owner, asset, source SHA-256, pipeline
  version)`, claim leases, five bounded attempts, backoff, explicit retry,
  `queued/running/complete/no_faces/error/denied` states and stale-lease fencing.
* Separate observations, generated clusters, stable people, manual track
  assignments, reversible merge redirects, aliases, negative matches and
  append-only correction history. A merge is a cluster association, **not training**.
* Cosine threshold **0.45**, ambiguity margin **0.05**, up to eight representatives
  per identity / 2,000 representatives per matching operation. These constants
  were fixed before testing the six portraits. Larger libraries can fragment
  beyond that matching window; no billion-image accuracy/scalability claim.
* Every public route validates a JWT and calls Library for live enabled
  membership. A user's subject comes from the JWT, never a request owner field.
  Owner-private labels cannot be read or changed by recipients of shared media.
  Face and person-asset reads additionally reauthorize each returned asset.
* Original bytes are fetched only after owner/source authorization, bounded and
  checked against the exact committed size/hash. The original is never changed.
  Face success is never used as a backup, deletion, retention or offload signal.
* Shared ServiceDefaults export OTel traces/logs/metrics to the existing Collector.
  Logs do not include images, embeddings, person labels or subjects.

## Deployed Library/gateway integration contract

The face service **does not grant authority merely because the caller possesses
the Storage service key**. The Library and gateway now implement these contracts:

1. `GET /v1/analysis/access`, normal JWT, **204** only for a currently enabled
   platform member, **403** otherwise. Faces forwards the original bearer token
   on *every* public request (there is no authorization cache).
2. `GET /internal/v1/analysis/owners/{subject}/assets/{assetId}`,
   `X-Nephos-Service-Key`, **200**
   `{ "id": UUID, "libraryId": UUID, "subject": string, "mediaType": string,
      "size": integer, "sha256": lowercase_hex }`
   only when the subject is live/enabled and owns that committed asset's private
   annotations. For this initial policy that means the asset's `uploaded_by`
   equals subject. It must be visible, not trashed, not pending, and a committed
   primary image rather than a hidden companion. Return **404** otherwise.
   The face worker checks this both before reading and before committing results.
3. Optional `GET /internal/v1/analysis/owners/{subject}/access` with the service key
   can expose a standalone enabled check. Faces currently does not need it:
   the source authorization endpoint must perform that check itself.
4. On committed Library asset visibility, durably publish/retry
   `POST http://faces-api:8080/internal/v1/faces/jobs`,
   `X-Nephos-Service-Key`, JSON `{ "assetId": UUID, "subject": uploaded_by }`.
   **202** means a durable idempotent face job exists; **404** means currently
   ineligible and must not break Library publication; transient failures should
   retry independently. Do not send events for pre-commit hidden companions.
   Library owns a transactional `face_publications` outbox with leases, backoff
   and idempotent HTTP delivery; this service does not consume
   the competing `nephos.assets.ready` projection queue.
5. Backfill enumerates Library-owned committed eligible images and sends the
   identical enqueue command. Repeating a backfill does not duplicate work.
   Migration `005_face_publication.sql` initially backfills eligible assets.
   A pipeline-version deployment requires `python3 scripts/faces-backfill.py`,
   which requeues in bounded, lease-fenced batches.
6. Route `/v1/faces/` to `faces-api:8080` in the gateway. Never expose
   `/internal/`, PostgreSQL or `face-inference:8090`.

The Storage peer endpoint is
`GET /internal/v1/assets/{assetId}/original` with `X-Nephos-Service-Key`.
There is no arbitrary path/URL input to either face API or inference.
Private image processing uses `/v1/infer` and `/v1/render`. Historical paths
remain aliases of v1 only; see [API compatibility](../specs/005-api-compatibility.md)
for coordinated deployment and future major-version rules.

## Start without disturbing the existing stack

From the project root:

```sh
python3 scripts/faces-env.py
docker compose --env-file .env --env-file .env.faces \
  -f compose.yaml -f compose.faces.yaml build migrate-library library-api library-worker \
  migrate-faces faces-api faces-worker face-inference
docker compose --env-file .env --env-file .env.faces \
  -f compose.yaml -f compose.faces.yaml up -d --no-deps faces-postgres
docker compose --env-file .env --env-file .env.faces \
  -f compose.yaml -f compose.faces.yaml up --no-deps migrate-faces
docker compose --env-file .env --env-file .env.faces \
  -f compose.yaml -f compose.faces.yaml up --no-deps migrate-library
docker compose --env-file .env --env-file .env.faces \
  -f compose.yaml -f compose.faces.yaml up -d --no-deps face-inference faces-api faces-worker
docker compose --env-file .env --env-file .env.faces \
  -f compose.yaml -f compose.faces.yaml up -d --no-deps library-api library-worker
curl --fail http://127.0.0.1:18085/health/ready
```

Wait for `faces-postgres` health before migrations if provisioning on a slower
host. The Library rebuild/migration/targeted upgrade is a **coordinated first-time
integration step**: it loads the source authorization routes and enables the
Library worker's `Analysis__Enabled` publisher through the face overlay. Omit
those base-service upgrades when Library is already current; do not interrupt
unrelated acceptance runs. The deployed gateway forwards `/v1/faces/` and
`/v1/analysis/access`; reload its updated configuration in the coordinated upgrade.
**Do not run an unqualified `up`, `down` or restart the existing stack.** `.env` is untouched;
additional secrets live in ignored mode-0600 `.env.faces` (also excluded by the
existing root Docker build context). Dedicated
`faces_owner` runs migrations; `faces_app` has only runtime table permissions.
Face inference is on a Docker `internal: true` network with no public port,
read-only filesystem, 1 CPU, 1.5 GiB RAM and 32 PID limit. The API has a
development-only loopback endpoint on port 18085.

For canonical HTTPS deployment, apply Compose overlays in this order:
`compose.yaml`, `compose.faces.yaml`, `compose.tls.yaml`,
`compose.faces.tls.yaml`. The last overlay supplies canonical HTTPS authority
and metadata configuration to both face processes. Development-only settings
are not a production authentication configuration.

**Backup gap:** the current `scripts/backup.py` backs up the base PostgreSQL,
media and RabbitMQ volumes, **not** `faces-postgres` or `.env.faces`. Until optional
face backup/restore is integrated, protect the face database and its credentials
separately with tested backup/restore procedures. Names, aliases, manual
assignments, negative constraints, merge/split decisions and correction history
are **not reconstructible from originals or regenerated embeddings**. Do not
describe these user annotations as rebuildable, or claim the existing backup
command protects them.

## API

All public paths below are prefixed `/v1/faces`, require JWT plus live enabled
membership, and return `Cache-Control: no-store`. List routes accept `limit=1..100`
and UUID `after`, and return `{items,next}`. Empty filtered pages can still have
`next`; follow it. Invalid limits are rejected, not silently enlarged.

| Method/path | Body or behavior |
|---|---|
| `POST /jobs/{assetId}` | Authorize owner's original and enqueue, 202 + job location |
| `GET /jobs`, `GET /jobs/{id}` | Persistent status/error/provenance; no internal lease token |
| `POST /jobs/{id}/retry` | Reset failed/denied current-version jobs; worker reauthorizes |
| `GET /people[?name=exact_name_or_alias]` | Bounded identities; ambiguous names return every match |
| `GET /people/{id}` | Stable record, aliases and optional `redirectId` |
| `PUT /people/{id}/name` | `{"name":"Publisher label","aliases":["Alias"]}` |
| `POST /people/{id}/merge` | `{"targetId":"..."}`; preserves source record/provenance |
| `DELETE /people/{id}/merge` | Undo that source redirect; names and original groups survive |
| `POST /people/{id}/negative-matches` | `{"otherId":"..."}`; rejects contradictory future merges |
| `DELETE /people/{id}/negative-matches/{otherId}` | Remove an incorrect negative constraint, retaining its correction history |
| `GET /observations[?assetId=...&personId=...]` | Stable track IDs, normalized boxes, quality, provenance; **no embeddings** |
| `PUT /observations/{id}/person` | `{"newPerson":true}` splits; `{"personId":"..."}` assigns; `{"personId":null}` explicitly marks unknown |
| `GET /people/{id}/assets` | Bounded currently-authorized asset IDs; follows merge redirects |
| `GET /corrections` | Owner-private bounded correction metadata |

Generated observations are immutable. Reprocessing retains old model rows and
manual correction records. Current public observations and matching use exactly
the active pipeline version; embeddings from incompatible versions are never
compared. Reprocessing matches stable tracks only on the same asset/source hash
and bounding-box IoU ≥0.6. Unmatched old manual tracks remain historical, not
silently assigned to another detected face. A deployment that changes coordinate
conventions must version preprocessing and provide a suitable track migration.
Merge chains are bounded to 32; cycles/deeper chains/negative contradictions
return 409. Future matching preserves the original winning representative's
cluster lineage even while a merge is active, so undoing that merge can also
restore faces matched subsequently. Negative constraints can be removed through
the API without erasing their audit history.

## Limits and honest scope

Accepted originals: single-frame **JPEG, PNG, WebP and HEVC-coded HEIC/HEIF**,
≤20 MiB, ≤64 million pixels, ≤64 detections. This includes 12/24/48-MP
iPhone HEIC originals within those limits. There is no
client-side conversion requirement: inference decodes an in-memory copy and
returns the SHA-256 of the unchanged original upload.
Animated images, HEIF sequences, multiple independent top-level images,
non-HEVC HEIF codecs and sampled video frames are not supported.
Unsupported images never become a `no_faces` success. An image without
detections is `no_faces`; detections smaller than 48 pixels are preserved as
`too_small` with no embedding/person (unknown), not forcibly identified.
Unlabelled high-quality clusters have stable IDs but null names, not guessed
names. A person name is supplied by the user.
`usable` means only the detector confidence/size gates passed; it is not a
sharpness or liveness guarantee. These identities must never authorize access,
replace passkeys, or make biometric authentication decisions.

EXIF transpose happens before detection/alignment; boxes are relative to the
upright full-resolution image (`exif-normalized`). Detection downsizes to a
maximum dimension of 1280; SFace receives an aligned face crop, not the entire original.
For newly supported images above 32 million pixels, the decoded RGB canvas is
first capped at 4096 pixels on its longest edge, before NumPy/OpenCV allocation.
Returned width/height describe the upright original, while normalized coordinates
map directly back to it. Inputs within the previous supported range keep their
existing alignment preprocessing, avoiding invalidation of stored embeddings or
manual identities. Migration `faces/004` retries previously failed inference jobs
once; successfully completed annotations/corrections are not reset.
For HEIF, libheif first applies container `irot`/`imir` transforms and grid
assembly; pillow-heif clears descriptive EXIF orientation to prevent applying
the same rotation twice. EXIF-only rotation without HEIF transforms is not
treated as authoritative, following HEIF presentation semantics. Embedded
thumbnails, depth and gain-map auxiliary images are not separately indexed;
only the single primary display image is used. A collection with multiple
top-level images is rejected, not silently reduced to its selected primary.
Sequence brands and movie tracks are rejected even when a still preview exists.

The existing RGB convention is unchanged: no ICC-to-sRGB transform is added
for JPEG or HEIF. Native HEVC YCbCr conversion supplies RGB samples; ICC/P3
profile values are not reinterpreted with a new color-management pipeline.
10/12-bit samples are reduced to 8-bit by the decoder; this is **not HDR tone
mapping** and auxiliary gain maps are not applied. Wide-gamut/HDR accuracy is
not qualified. Both frozen model and preprocessing versions remain unchanged:
previously supported inputs retain the same numerical pipeline; the new large-image
canvas extends a previously rejected input domain. Existing completed annotations
are neither recalculated nor erased.
Any future color-management or tone-mapping change needs a coordinated
preprocessing-version bump and reprocessing policy.

Inference concurrency is one; each request runs a killable child with a 45-second
wall timeout, 40-second CPU and 2-GiB address-space ceiling. The container's
1.5-GiB memory ceiling is stricter. Model checksums are verified on startup and
per child. Native decoder isolation is resource containment, not a proof of
absence of decoder vulnerabilities. Production needs ordinary dependency patching.
HEIF uses one decode thread, keeps libheif's security limits enabled, and checks
container structure/frame count and dimensions before pixel loading (and
dimensions again afterward). Decoder failures return sanitized reasons such as
`unsupported_image`, `unsupported_sequence`, `animated_image`, `corrupt_image`,
`pixel_limit` or `payload_limit`, never native exception text.

Annotation sharing/grants, recipient-owned annotation views, video indexing,
model training, semantic/person combined search and native People UX are not
implemented by this service. This does not claim whole-platform completion.

## Model weights licenses and reproducibility

OpenCV Zoo revision: `48b10fa505aeb51fbd127fc60a5c660040e823b7`.
The pinned model-directory READMEs expressly say **all files in the directory**
are licensed under the respective license; this covers the ONNX weights, not
merely the OpenCV Python library. Those READMEs and full licenses are retained in
`licenses/`; upstream provenance and lengths are in `models.json`.

| Model | Weight license | Bytes | SHA-256 |
|---|---|---:|---|
| `face_detection_yunet_2023mar.onnx` | MIT, Shiqi Yu | 232589 | `8f2383e4dd3cfbb4553ea8718107fc0423210dc964f9f4280604804ed2552fa4` |
| `face_recognition_sface_2021dec.onnx` | Apache-2.0; SFace contributed by Yaoyao Zhong, ONNX conversion by Chengrui Wang | 38696353 | `0ba9fbfa01b5270c96627c4ef784da859931e02f04419c829e83484087c34e79` |

Build downloads are bounded to the pinned lengths and SHA-256 verified. Model
downloads happen at image build time, never from a user-controlled URL; runtime
inference has no external network. Redistributing the image must retain included
model licenses/attributions. No warranty about upstream training-data rights or
generalization is implied by the weights' license.

## HEIF dependencies, builds and licenses

Pinned Python binding: **pillow-heif 1.8.1**, BSD-3-Clause source. The upstream
prebuilt wheels also bundle **GPLv2 x265 encoding**, in addition to LGPLv3
libheif/libde265; calling the upstream wheel merely BSD would be incorrect.
`requirements.txt` is convenient for **local tests/fixture generation**, whose
encoder produces our derived fixtures. Do not copy that development environment
into the production image.

The Dockerfile instead builds the binding from its checksum-pinned source,
**libheif 1.23.6** and **libde265 1.1.3** (LGPLv3), dynamically linked, with x265,
other external encoders/codecs and plugin loading disabled. A build assertion
requires the only decoder to be `libde265` and no HEVC/AVIF encoder; libheif's
internal mask helper is not a HEVC encoder. No GPL x265 wheel or library enters
the final image. `heif-native.json` pins URLs, lengths and SHA-256 for all three
source archives; `build_heif.py` is the reproducible build recipe.

`licenses/pillow-heif-LICENSE.txt`, `licenses/pillow-heif-LICENSES_bundled.txt`,
`licenses/libheif-COPYING` and `licenses/libde265-COPYING` retain unmodified
upstream notices. The bundled-wheel notice describes the **development wheels**,
not the custom decoder-only build. The runtime also includes corresponding
unmodified sources in `/opt/heif/share/sources` and notices in
`/opt/heif/share/licenses`; the recipe/manifest are in `/app`. Native shared
libraries in `/opt/heif/lib` remain replaceable/relinkable. First-party license
restrictions must not override third-party LGPL rights, including modification
and reverse engineering for debugging such modifications. Distributors must
preserve applicable notices/source and comply with third-party terms;
HEVC patent rights are a separate question, not granted by these licenses.

CPython 3.12 manylinux wheels for **amd64 and arm64**, including the other
pinned Python requirements, were resolved explicitly. The source-built runtime
is used instead to avoid the wheel's encoder license. See
`fixtures/heic-build-verification.json` for actual architecture/build checks,
distinct from wheel availability.

## Reproducible verification

The base Compose deployment also runs `image-derivatives`, a separate private,
read-only renderer built from this Dockerfile's `image-tools` stage, without model
weights. It shares the checked codec/EXIF decoder but has its own one-request
admission limit, killable child and 1.5-GiB container. It emits stripped-metadata
JPEG previews with maximum dimensions 512, 1280 and 2560, without upscaling.
Display previews convert embedded ICC profiles to sRGB before stripping metadata;
invalid profiles are rejected explicitly. This display-only conversion does not
change the legacy ML RGB convention or imply HDR/gain-map tone mapping.
Storage binds responses to the original SHA-256 and caches fixed variants
atomically. Public `GET /v1/assets/{id}/preview?size=512|1280|2560` applies live
Library authorization; omitting size retains the 512 contract. Unsupported sizes
fail with 400. Old/missing variants are created on demand. Renderer outages never
replace or invalidate originals; previews fail explicitly and may be retried.
The existing `hasPreview` field is a publication-time hint, not a permanent
negative capability: clients may request a missing variant even when it is false.
Video/GIF preview frames retain the bounded ffmpeg path.

On 2026-10-31, the generated 6048x8064 HEIC fixture (8,217,272 bytes on local
arm64) passed actual uploaded-file processing and matched its existing named
JPEG identity. In isolated production-limited Linux arm64 containers, peak child
RSS was 416,848 KiB for inference and 390,612 KiB for rendering. Both completed
within their 45-second deadlines. This upscaled attributed portrait proves the
large-image path, not 48-Mp physical-camera/HDR quality. Full native camera
qualification and broader accuracy evaluation remain separate.

```sh
python3 -m venv face-inference/.venv
face-inference/.venv/bin/python -m pip install -r face-inference/requirements.txt
python3 face-inference/download_models.py
face-inference/.venv/bin/python face-inference/fixtures/download.py
face-inference/.venv/bin/python face-inference/fixtures/evaluate.py
face-inference/.venv/bin/python face-inference/fixtures/generate_heic.py
# Required for faces-smoke.py; optional for standalone decoder tests. Never redistributed.
face-inference/.venv/bin/python face-inference/fixtures/download_camera.py
face-inference/.venv/bin/python face-inference/fixtures/evaluate_heic.py
face-inference/.venv/bin/python -m unittest discover -s face-inference -p 'test_*.py'

# Test-only loopback database access; does not expose the normal platform DB.
docker compose --env-file .env --env-file .env.faces \
  -f compose.yaml -f compose.faces.yaml -f deploy/faces/compose.test.yaml \
  up -d --no-deps faces-postgres
python3 scripts/faces-tests.py
```

The test script migrates **faces_tests**, not the production face database.
`.NET` tests distinguish deterministic vector/control-adapter tests from the
six-photograph test, which executes the real detector/embedding subprocess for
each durable API-created job and verifies three groups, names, merge/undo/split
and restart persistence. The fixture Library/Storage adapter in that test is
controlled; it is **not** proof that a real Library deployment is wired.
Actual HTTP inference is separately testable inside the private container.

After deploying the complete development stack and downloading the six licensed
JPEG fixtures above, prepare both required HEIC fixture sets before the live smoke:

```sh
face-inference/.venv/bin/python face-inference/fixtures/generate_heic.py
face-inference/.venv/bin/python face-inference/fixtures/download_camera.py
python3 scripts/faces-smoke.py
```

The smoke verifies real Keycloak JWTs, exact-original uploads,
hash/storage/RabbitMQ/Library projection, **automatic** indexing, private CPU
inference, three expected portrait groups, shared-reader/cross-owner isolation,
live disablement/membership checks, compound pending/hidden-primary gates and
correction persistence across actual face-container restarts. It also briefly
stops **only `faces-api`** to prove durable delivery retry while original upload
and retrieval remain available; coordinate that face-only outage before running.
It cleans up its disposable accounts, originals and biometric annotations and
writes `artifacts/faces-live-smoke.json`. It never restarts base services and
does not install an authentication bypass.
The deployed HEIC checks also passed: six `image/heic`/`image/heif` portraits
automatically join their existing named JPEG identities, with unchanged original
bytes/hashes and upright dimensions/boxes; an orientation-6 original produces
470×640 upright coordinates. HEIC compound-primary/hidden-companion eligibility,
backfill of a preexisting grid HEIC after the actual Faces outage, and the exact
public iPhone 12 Pro camera original uploaded through the API (`no_faces`) are
covered alongside the existing privacy, correction and restart checks.

`fixtures/provenance.json` records original URLs, source pages, attribution,
licenses, dates, source labels and SHA-256. No unauthorized copyrighted images
are committed; downloaded licensed originals stay ignored. In particular,
Obama's 2009 portrait is **CC BY 3.0, Pete Souza**, not public domain. No image
was substituted or identity inferred visually. All six exact original downloads
are passed to inference; EXIF normalization/downscaling are model preprocessing,
not replacement fixtures. See `fixtures/validation.json` for actual observed
similarities and limitations; raw local output/embeddings stay in ignored
`results/`. Six controlled portraits are a smoke test, not a representative
family-photo accuracy benchmark.

### HEIC evidence and its boundaries

`fixtures/generate_heic.py` generates genuine HEVC-encoded HEIF files from those
same attributed portraits, retaining dimensions for all six. Its ignored
outputs are `fixtures/heic/{source-id}.heic`, orientation cases
`obama-2009-orientation-{1..8}.heic`, grid/10-bit/multiple-image cases, and
`fixtures/heic/provenance.json` (`fixtures[]` records output hashes, original
hashes, attribution, transformations and `cameraOriginal:false`). The fixed
encoder settings make these repeatable codec fixtures on a pinned runtime;
cross-platform encoders need not produce byte-identical compressed files.
No generated HEIC is represented as an untouched camera original.

`test_decoder.py` performs actual YuNet/SFace inference, verifies one nonempty
128-dimensional embedding per portrait, cosine similarity >0.95 against its
original JPEG, normalized boxes and original hashes; all mirrored/rotated cases
must match the upright embedding >0.99. It also checks 512px grid tiles, 10-bit
SDR decoding, collection/sequence/codec/corruption/pixel/payload rejection,
isolated child inference and the unchanged HTTP timeout policy.
`fixtures/evaluate_heic.py` additionally checks JPEG-to-HEIC matching across
**different photographs** of each source-labelled person using the unchanged
0.45 threshold. Checked-in numerical evidence is
`fixtures/heic-validation.json`; raw output remains in ignored `results/`.

Separately, `fixtures/camera-source.json` identifies a public **iPhone 12 Pro**
camera-origin sample (publisher claim plus Apple/iPhone EXIF): 3024×4032,
orientation 8, 512px tiles, 8-bit, embedded ICC profile. The publisher explicitly
allows software testing; no broad redistribution license is inferred. The
bounded checksum-verifying `download_camera.py` fetches it into ignored
`fixtures/camera/`; it is optional for standalone decoder tests but required for
the full-stack smoke, and excluded from production images.
It decodes upright without modifying bytes and has **no human faces**.
Its exact public original has also passed upload, storage and automatic
inference through the deployed API. That is a camera-origin **API upload** test,
not an upload initiated from a physical iPhone's Photos library.
These camera-origin and generated human-face checks do
**not** qualify all camera devices or substitute for a physical iPhone Photos
permission/export/original-upload/restore round-trip. Real HDR, auxiliary-depth,
Live Photo, different iOS versions and 48-MP inputs remain explicit gaps.
