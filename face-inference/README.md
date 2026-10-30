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
2. `GET /internal/analysis/owners/{subject}/assets/{assetId}`,
   `X-Nephos-Service-Key`, **200**
   `{ "id": UUID, "libraryId": UUID, "subject": string, "mediaType": string,
      "size": integer, "sha256": lowercase_hex }`
   only when the subject is live/enabled and owns that committed asset's private
   annotations. For this initial policy that means the asset's `uploaded_by`
   equals subject. It must be visible, not trashed, not pending, and a committed
   primary image rather than a hidden companion. Return **404** otherwise.
   The face worker checks this both before reading and before committing results.
3. Optional `GET /internal/analysis/owners/{subject}/access` with the service key
   can expose a standalone enabled check. Faces currently does not need it:
   the source authorization endpoint must perform that check itself.
4. On committed Library asset visibility, durably publish/retry
   `POST http://faces-api:8080/internal/faces/jobs`,
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

The unchanged Storage peer endpoint is
`GET /internal/assets/{assetId}/original` with `X-Nephos-Service-Key`.
There is no arbitrary path/URL input to either face API or inference.

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

Accepted originals: single-frame **JPEG, PNG and WebP**, ≤20 MiB, ≤32 million
pixels, ≤64 detections. No HEIC, animated images or sampled video-frame indexing
yet. Unsupported images never become a `no_faces` success. An image without
detections is `no_faces`; detections smaller than 48 pixels are preserved as
`too_small` with no embedding/person (unknown), not forcibly identified.
Unlabelled high-quality clusters have stable IDs but null names, not guessed
names. A person name is supplied by the user.
`usable` means only the detector confidence/size gates passed; it is not a
sharpness or liveness guarantee. These identities must never authorize access,
replace passkeys, or make biometric authentication decisions.

EXIF transpose happens before detection/alignment; boxes are relative to the
upright full-resolution image (`exif-normalized`). Detection downsizes to a
maximum dimension of 1280; SFace aligns from the full decoded upright image.
Inference concurrency is one; each request runs a killable child with a 45-second
wall timeout, 40-second CPU and 2-GiB address-space ceiling. The container's
1.5-GiB memory ceiling is stricter. Model checksums are verified on startup and
per child. Native decoder isolation is resource containment, not a proof of
absence of decoder vulnerabilities. Production needs ordinary dependency patching.

Annotation sharing/grants, recipient-owned annotation views, video/HEIC,
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

## Reproducible verification

```sh
python3 -m venv face-inference/.venv
face-inference/.venv/bin/python -m pip install -r face-inference/requirements.txt
python3 face-inference/download_models.py
face-inference/.venv/bin/python face-inference/fixtures/download.py
face-inference/.venv/bin/python face-inference/fixtures/evaluate.py
face-inference/.venv/bin/python face-inference/test_inference.py

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

After deploying the complete development stack, run
`python3 scripts/faces-smoke.py` for real Keycloak JWTs, exact-original uploads,
hash/storage/RabbitMQ/Library projection, **automatic** indexing, private CPU
inference, three expected portrait groups, shared-reader/cross-owner isolation,
live disablement/membership checks, compound pending/hidden-primary gates and
correction persistence across actual face-container restarts. It also briefly
stops **only `faces-api`** to prove durable delivery retry while original upload
and retrieval remain available; coordinate that face-only outage before running.
It cleans up its disposable accounts, originals and biometric annotations and
writes `artifacts/faces-live-smoke.json`. It never restarts base services and
does not install an authentication bypass.

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
