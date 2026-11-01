# Nephos

Self-hosted original photo/video backup with an ASP.NET Core backend and a native
[iOS client](ios/README.md). Implementation is on `feature/mvp-foundation`;
[the execution plan](specs/004-mvp-execution-plan.md) records the wider roadmap.

**License:** proprietary; use requires explicit written permission from the
copyright holder. This is **not the Unlicense**. Third-party dependencies,
models and test media retain their own licenses; see [LICENSE](LICENSE).

## What is implemented

Production-grade engineering is the required baseline for **every feature and
service**, including native clients, administration, ML and deployment.
Incremental delivery limits scope, not correctness, security or operability.
The [shared completion standard](specs/000-media-platform.md#14-engineering-and-completion-standard)
applies to all implementation work. The inventory below describes functionality,
not a claim that the entire platform is production-qualified.

- Explicit [API major-version contracts](specs/005-api-compatibility.md):
  public `/v1`, private `/internal/v1`, and v1-pinned legacy peer aliases.
- Optional [Bonjour LAN discovery](deploy/discovery/README.md): a host-side
  advertiser and native iOS server picker, with HTTPS/OIDC verification and
  explicit trust preserved.
- Known-user Keycloak authentication; real JWT validation and immediate platform
  disablement checks. No public registration or application password grant.
- A separate, localhost-only administration console for known users, personal
  libraries, membership enablement, single-use 30-minute first-login PINs, and
  per-device session revocation.
- Idempotent upload intents, 4 MiB immutable out-of-order chunks, persisted part
  receipts, resumable status, cancellation before sealing, and asynchronous
  SHA-256/length verification. Uploads are limited to 8 GiB each, 16 pending per
  user, and 64 GiB of pending reservations globally; idle uploads expire after 24h.
- Content-addressed originals on a mounted volume, file/directory durability
  flushes, separate physical blob references, and same-library/owner duplicate
  short-circuiting. A different user's hash knowledge cannot skip uploading bytes.
- Separate verification and library-projection workers. Transactional outbox,
  RabbitMQ publisher confirms, durable queues, manual acknowledgements,
  idempotent projection, and a dead-letter queue.
- Authorized gallery pages, year/month/day counts, JPEG previews when supported,
  exact originals with HTTP Range, and fresh backup evidence. Chronology uses
  supplied capture date or upload date; originals are never transcoded.
- Immutable seven-day gallery snapshots, bounded atomic change batches, and
  access-generation fencing. New uploads cannot change an existing view's
  pages or date counts.
- Immutable complete resource-set manifests for compound Photos assets.
  Constituent uploads remain hidden until the whole set is published; retention
  evidence covers every original, not just its representative image.
- Owner-controlled selected-media or all/future-media sharing with known users;
  shared provenance, scoped snapshots/deltas, revocation and read-only grants.
- Native media-first iOS navigation, chronological preview grid, full-screen
  photo viewing, upload progress/pause, and persistent System/Light/Dark themes.
  People screens use real private face crops and support names, aliases, merges,
  undo, reassignment, splitting and different-person rules. Native sharing
  includes selection, known-user discovery, scope changes and revocation.
- Optional [owner-private face service](face-inference/README.md): local CPU
  detection/embeddings, stable person clusters, names, aliases, reversible
  merges/splits and manual negative matches. A transactional Library outbox
  automatically queues eligible committed primary photos independently of backup.
- Renewable, persisted 30-day retention holds with fresh original rehashing for
  eligible phone cleanup. User deletion retains originals for 30 days; only the
  scheduled reference-aware cleanup service can reclaim expired server bytes.
- Shared OpenTelemetry logs/metrics/traces and Grafana/Prometheus/Loki/Tempo,
  including propagation through verification, the outbox, and projection.
  The private Python administration service exports all three signals through
  the same Collector and propagates trace context into the administration API.
  Provisioned operational dashboards and alert rules cover worker liveness,
  storage headroom, verification, publication backlogs, and dead letters.

The current implementation is **not yet production-qualified as a whole**.
Server albums/favorites, semantic search, APNs, Android, HA, and multi-host
workload/network isolation remain unfinished. Face analysis currently supports
JPEG/PNG/WebP/HEIC/HEIF still images, not video. HEIC is decoded only inside the
bounded analysis service; the phone uploads its original and the stored bytes,
hash and download format stay unchanged. Existing eligible HEIC/HEIF primaries
are queued by Library migration `006`; `scripts/faces-backfill.py` can safely
repeat discovery. Analysis accepts up to 20 MiB / 64 million pixels, including
48-Mp HEIC. Above the previous 32-Mp boundary, a temporary image capped at 4096
pixels is prepared before OpenCV; face boxes remain normalized against the
upright original. Existing supported-image embeddings and labels are preserved.
The private `image-derivatives` service generates 512/1280/2560-pixel JPEG
previews. iOS grids and photo viewing use previews, not original downloads;
originals are fetched explicitly for export/restore (video playback uses bounded ranges).
See the iOS documentation for supported resource restoration and
device-only acceptance checks; a simulator build does not certify Face ID,
background scheduling, or Photos deletion.

The native Search screen currently supports case-insensitive substrings of person names/aliases and
explicitly scoped filename filtering of loaded items, not semantic search.
The Albums tab exposes libraries and incoming/outgoing sharing; server album
creation is explicitly unavailable. See the
[remaining feature list](ios/README.md#remaining-features) rather than treating
every design mockup as an implemented backend capability.

## Start locally

Requires Docker Compose, Python 3, and .NET SDK 10.0.300 for local .NET builds.
The complete stack needs several GB of memory and free disk space.

```sh
python3 scripts/dev-env.py                   # first setup only
# python3 scripts/upgrade-dev-env.py         # existing foundation .env instead
docker compose up -d --build
```

Credentials and a stable server ID are generated into ignored, mode-0600 `.env`.
The generator refuses to overwrite it; the upgrade helper only adds missing
settings, including the Keycloak PIN pepper, isolated identity-admin key and API
introspection credential.
Environment edits do not rotate credentials already stored in volumes.

| Local address | Purpose |
|---|---|
| `http://localhost:18080` | Backend API and `/v1/config` |
| `http://localhost:18082` | Dedicated administration console, username `admin` |
| `http://localhost:18081/admin/` | Keycloak provider administration, username `admin` |
| `http://localhost:18083` | Development-only email inbox for unrelated local services (Mailpit) |
| `http://localhost:13000` | Grafana, username `admin` |

The Nephos console has a normal **Sign in** page. It redirects to the private
Keycloak operator login and returns to the console; it never uses a browser
Basic Auth dialog or receives your password. Use `KEYCLOAK_ADMIN_PASSWORD`
from `.env` with username `admin` for both private administration consoles,
and `GRAFANA_PASSWORD` for Grafana. Do not share or commit them. PostgreSQL,
RabbitMQ and OTLP have no host-published ports. All development host ports bind
to loopback, not the LAN.

For existing installations, run `python3 scripts/upgrade-dev-env.py` before
rebuilding the administration services. See
[administration deployment and recovery](deploy/administration.md) for the OIDC
bootstrap, private origins, session lifecycle and verification commands.

In the Nephos administration console, create a user and personal library.
The user enters only their email initially in the native iOS app; a known,
enabled account receives a sign-in request, not the PIN. Read **Requested
sign-in PINs** in the private console and give the 8-digit PIN directly to the
verified user; it is one-use, expires after 30 minutes, and is never emailed.
The user then enters the PIN in the app. The PIN exchange creates a revocable
Keycloak device session with a persistent offline refresh token.

Then follow [ios/README.md](ios/README.md) to build/run the native client, approve
the server, sign in, select a library, and import Photos resources. Automatic
backup and phone cleanup are independent opt-in settings, initially off.

## API

All media/library/upload routes require a Keycloak access token with audience
`nephos-api` and enabled platform membership. Possessing a provider account alone
does not confer library access.

| Method and path | Contract |
|---|---|
| `GET /v1/config` | Public versioned-client setup values and stable server identity |
| `GET /v1/libraries?limit=50&after=<uuid>` | Membership-scoped library pages |
| `GET /v1/faces/people` | Optional owner-private person identities; see the face service API documentation |
| `POST /v1/uploads` | `{id,libraryId,fileName,mediaType,size,sha256,capturedAt?}` |
| `PUT /v1/libraries/{id}/resource-sets/{setId}` | Immutable `{kind,sourceRevision,primaryAssetId,resources}` manifest |
| `GET /v1/resource-sets/{id}` | Complete authorized resource manifest |
| `GET /v1/assets/{id}/resources` | Manifest containing this resource |
| `DELETE /v1/assets/{id}` | Owner-only logical deletion of the complete resource; starts a 30-day recovery period |
| `GET /v1/trash?limit=50&before=<deletedAt>&beforeId=<uuid>` | Owner-only trash page `{items:[{asset,deletedAt,purgeAfter}],nextCursor}` |
| `GET /v1/trash/{id}/preview?size=512` | Owner-only retained preview; normal content routes still reject deleted assets |
| `POST /v1/assets/{id}/restore` | Clear deletion markers atomically for the complete resource; 204, 404 unowned, 409 expired |
| `POST /v1/resource-sets/{id}/retention` | Owner-only fresh evidence/holds for every resource, or failure |
| `GET /v1/uploads/{id}` | State, received zero-based part indexes, chunk size, error, committed asset ID |
| `PUT /v1/uploads/{id}/parts/{index}` | Exact raw bytes with expected Content-Length; identical retry is idempotent |
| `POST /v1/uploads/{id}/complete` | Seal a complete part set; return 202 while verification/projection run |
| `DELETE /v1/uploads/{id}` | Cancel an unsealed upload; never delete a committed original |
| `GET /v1/libraries/{id}/assets?limit=50` | Gallery page plus `{createdAt,id}` continuation cursor |
| `GET /v1/libraries/{id}/timeline?year=2026&month=10` | UTC counts: omit month for months, omit both for years |
| `POST /v1/libraries/{id}/snapshots` | Retained `{id,revision,accessGeneration,expiresAt,totalCount}` |
| `GET /v1/libraries/{id}/snapshots/{snapshot}/assets` | Frozen gallery pages using the same bounded cursor |
| `GET /v1/libraries/{id}/snapshots/{snapshot}/timeline` | Frozen UTC counts with the same year/month filters |
| `GET /v1/libraries/{id}/changes?after=1&through=5&limit=20` | Whole revision batches through a retained target snapshot |
| `GET /v1/assets/{id}/original` | Authorized exact original, supporting Range/HEAD |
| `GET /v1/assets/{id}/preview` | JPEG preview or 404 when unavailable |
| `GET /v1/assets/{id}/backup` | Fresh committed-reference/file availability evidence |
| `POST /v1/assets/{id}/retention` | Owner-only rehash and renewable 30-day hold |

Gallery continuation uses `before=<createdAt>&beforeId=<id>`, both required
together. Library/gallery pages accept 1-100 entries. The upload UUID is a stable
client idempotency key and becomes the asset ID. An authorized duplicate may
return a previous upload ID; use the ID returned by the server. `ready` means
the verified original/reference and library projection are all committed.
Chunk acknowledgment or a 202 response alone is **not backup completion**.

Compound intents additionally carry a stable `resourceSetId`. Each manifest
resource declares `assetId`, `role`, `sha256`, `size`, `fileName`, and
`uniformTypeIdentifier`; 1-16 distinct, owned, committed resources are required.
Kinds are `single`, `live-photo`, `raw-jpeg`, `edited`, and `archive`.
An individual constituent becoming `ready` does not complete the set. Reusing
verified bytes for a different set creates a distinct logical reference without
retransmitting bytes. Incomplete/conflicting manifests do not publish partial sets.

Snapshots retain their original ordering/counts for seven days, with up to 20,000
active views per user/library; unchanged frontiers reuse a recent snapshot.
Catch-up requests must reference retained starting/target views. Apply all pages
through the fixed target atomically before committing the new local token.
HTTP 410 requires a fresh snapshot; unavailable membership returns 404.
Publication and resource grouping share one transactional revision frontier.
History retains asset versions and synchronization tombstones after physical
purge; there is no history-compaction API.

Deletion immediately hides the asset from ordinary and shared views, without
releasing original references. Repeat deletion does not extend the 30-day deadline.
Restore changes only server state: the same asset IDs, originals, resource-set
membership and retained analysis are reused; it never recreates a Photos copy.
The separately deployed daily cleanup service claims expired assets irreversibly,
releases Storage references, removes Faces derivatives, then records completion.
Restore rejects expired or claimed assets. Storage honors other references and
retention holds, so physical bytes may remain longer than 30 days.

The API preserves JPEG/PNG/HEIC/HEIF/WebP/GIF, MP4/QuickTime, or explicitly typed
octet-stream bytes. Unsupported/undecodable previews do not rewrite or discard
originals. FFmpeg runs in the bounded worker with an input-format/protocol
allowlist and timeout. The retention path rehashes originals, not thumbnails.

## Phone cleanup safety

The client must match the complete unchanged local source revision, hash and size,
obtain fresh retention assurance, and honor Photos confirmation. Unsupported
compound/edited resources remain ineligible. Hold expiry prevents starting a new
removal attempt; server and OS operations are not an atomic transaction.

The server declares **`single-volume-no-independent-backup`**: references/holds
protect against application release, not disk failure, ransomware, or operator
deletion. RAID is not an independent backup. Photos deletion can propagate to
iCloud and other devices; it is not an iCloud-original cache-eviction API.

## Validation

GitHub Actions runs separate quality/secret, backend build/unit, integration/
recovery, real-model face integration, and native iOS jobs on pushes and pull
requests. Actions and downloaded scanners are pinned; CI uses temporary generated
development credentials, not deployment secrets.

Local lint and secret checks:

```sh
python3 -m venv .venv
.venv/bin/python -m pip install -r scripts/quality-requirements.txt
.venv/bin/ruff check .
.venv/bin/ruff format --check .
.venv/bin/yamllint -s .github compose*.yaml deploy tests/alert-rules.test.yaml .yamllint.yaml
actionlint
shellcheck .githooks/pre-commit .githooks/pre-push
dotnet format Nephos.slnx --verify-no-changes --no-restore
swift format lint --strict --recursive ios/Nephos ios/Tests ios/Qualification ios/Package.swift
python3 scripts/secret_scan.py --history
python3 -m unittest discover -s scripts -p 'test_*.py'
```

Install Gitleaks **8.30.1**, actionlint **1.7.12**, ShellCheck and the required
.NET/Xcode toolchains first. Use `ruff format .` and `swift format format
--in-place --recursive <paths>` to apply formatting. OIDC wire DTO names retain
their protocol spelling through a narrowly scoped Swift lint exemption.

Enable the committed local hooks with `git config core.hooksPath .githooks`
(integrate manually if you already have hooks). The pre-commit hook scans exact
index bytes; pre-push also scans all available Git history. Normal scans include
tracked and non-ignored untracked source, never ignored local credentials/build
output. Accidentally staged `.env` files and private-key containers are rejected
even without a recognizable token. Findings are redacted; a scanner failure
blocks the check. Secret scanners reduce risk but do not prove absence of secrets.
Review staged files before publication. Third-party photo/model downloads,
simulator data, private `.env` files and backup archives stay ignored.

```sh
dotnet restore Nephos.slnx --locked-mode
dotnet build Nephos.slnx --no-restore
OTEL_SDK_DISABLED=true dotnet test Nephos.slnx --no-restore
dotnet format Nephos.slnx --verify-no-changes --no-restore
python3 scripts/smoke.py
python3 scripts/admin-smoke.py
python3 scripts/media-smoke.py
python3 scripts/release-smoke.py
python3 scripts/operations-smoke.py
python3 scripts/edge-smoke.py
python3 scripts/identity-production-smoke.py
python3 scripts/low-storage-smoke.py
python3 scripts/restore-smoke.py
python3 -m pip install -r scripts/browser-requirements.txt
python3 -m playwright install chromium
python3 scripts/passkey-smoke.py
```

Run smoke scripts only against the disposable local profile. They create/remove
test users and records, briefly stop/restart the Collector/broker/API, and
validate real JWT/JWKS and immediate Keycloak session revocation, PostgreSQL, immutable chunk retry, restart/resume,
verification failure, deduplication, authorization, original/ranged bytes,
previews, retention, paging, first-login PIN issue/one-use exchange and stored correlated telemetry.
The browser suite uses Keycloak's virtual authenticator to exercise the existing
passkey flow through disposable Keycloak enrollment emails (not the PIN-only admin
console), signs in with Code+PKCE, verifies membership denial (403) and full account
revocation (401), and exercises credential recovery without restoring platform
membership. This is not a physical iOS passkey or real Photos
removal test. The edge suite exercises the actual Caddy route configuration
on a temporary loopback HTTP listener; it does not certify DNS or certificates.
The restore exercise pauses writers, restores isolated PostgreSQL/RabbitMQ/media
volumes, checks original bytes, complete manifests and frozen views against their
restored references, verifies a pending publication survives, and resumes the
source deployment. A separate disposable identity stack verifies production Keycloak startup,
first-login PIN issue/expiry/one-use exchange, offline refresh, device revocation,
immediate token introspection and proxy-aware HTTPS discovery without changing
the live realm.
The low-storage suite uses a tiny temporary RAM-backed volume, never fills the
host disk, and verifies that rejected admission leaves no upload state.
The CI workflow repeats backend checks; native commands live in `ios/README.md`.
The native CI job runs deterministic Swift tests and signing-disabled Debug/Release
simulator builds. To exercise the real Swift client against this running backend:

```sh
python3 ios/run_native_e2e.py
```

That opt-in test uses the production Swift HTTP/upload client with an ephemeral
signed-token fixture. It is distinct from interactive passkey/Photos-device E2E.
The simulator Photos restoration exercise **passes** for synthetic JPEG,
QuickTime video and Live Photo: re-exported originals match SHA-256/size, paired
semantics survive, and cleanup eligibility remains restricted to singles.
Physical-device background execution, camera RAW restoration, deletion,
production signing, and a real HTTPS deployment remain release gates.

Append SQL migrations rather than editing applied files. Rebuild migration images
and run both migration services after adding migrations. Runtime APIs use Npgsql
repositories, not EF. The separate library-administration process has owner
credentials and a distinct internal key that public API processes do not receive.

## HTTPS and operation

For a canonical DNS hostname with certificate issuance reachability:

```sh
PUBLIC_HOST=photos.example.net docker compose -f compose.yaml -f compose.tls.yaml up -d --build
```

The optional Caddy edge exposes only `/v1/*`, the `nephos` realm's login endpoints,
and provider static resources over HTTPS. Administration, master-realm token
endpoints, Mailpit, and Grafana remain private. No domain/certificate is invented
by this repository; use your real host and configure its DNS/trust. The mobile
client uses that canonical origin, not `localhost` on a physical phone.
Before switching to the public hostname, set the **master realm's** frontend URL
to the private Keycloak origin (`http://localhost:18081` by default). The TLS
profile sets its administration hostname separately with `PRIVATE_KEYCLOAK_URL`.
This keeps provider-console login on the private route; do not expose the master
realm publicly to work around a misconfigured redirect.

The local profile uses Keycloak development mode. The TLS overlay instead uses
Keycloak `start`, trusted proxy headers, and ASP.NET Core Production mode with
HTTPS issuer/discovery verification. The canonical public hostname must resolve
and be reachable from the containers as well as clients.
Internal service/database/broker traffic still trusts the host's private Docker
network; this is not multi-host mTLS or hostile-container isolation.
Broker provisioning creates separate publisher/projector identities with no
administration or queue-configuration permissions. APIs receive neither broker
administrator credentials nor worker passwords. Rerun `broker-init` when
deliberately rotating worker credentials; environment edits alone are not a
general database/provider credential-rotation procedure.

Telemetry queues/retries are bounded. Export failure must not block domain work;
telemetry is not the authoritative operation/audit journal. Prometheus retains
seven days/512 MB, Loki seven days, Tempo one day. Development trace sampling is
100%; the application default is 10%. Open **Nephos / Nephos operations** in
Grafana for service heartbeats, volume headroom, pending/failed uploads, queues,
active alerts, and trace-linked logs. Prometheus evaluates the provisioned rules;
external email/paging notification delivery is not configured. A stale sampler
has its own alert, so old storage gauges cannot be mistaken for fresh evidence.
Alert conditions can be exercised without waiting for wall-clock failures:

```sh
docker compose run --rm --no-deps \
  -v ./tests/alert-rules.test.yaml:/etc/prometheus/tests.yaml:ro \
  --entrypoint promtool prometheus test rules /etc/prometheus/tests.yaml
```

Before trusting the server as the only copy, keep cold backups on independent,
encrypted storage. The backup helper pauses running services, archives PostgreSQL,
media and RabbitMQ volumes plus `.env`, hashes the archives, and resumes services:

```sh
python3 scripts/backup.py create /private/backup/nephos-2026-10-25
python3 scripts/backup.py verify /private/backup/nephos-2026-10-25
python3 scripts/backup.py restore /private/backup/nephos-2026-10-25 --project nephos-restored
```

Creation refuses an existing destination. Restore refuses existing target volumes;
it never overwrites live data. Follow its printed Compose command using the
matching code/image versions and stop conflicting host ports before starting a
restored deployment. Verification uses temporary isolated containers with no
published ports and removes only those helpers. Raw-volume restores require
compatible database/broker versions and architecture. RabbitMQ uses a stable node
hostname so recreated containers retain queued work.

Archives contain **plaintext private media and credentials**; mode-0600 files
and checksums are not encryption or authenticity protection. Database-only
backups cannot restore originals. If using a non-default env file, set
`NEPHOS_ENV_FILE` for the backup helper. A successful local restore exercise is
not a promise against hardware failure or a substitute for real-device release
qualification.

```sh
docker compose down
```

Stops this project's containers and preserves named data volumes.
