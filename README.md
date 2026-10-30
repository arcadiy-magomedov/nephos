# Nephos MVP

Self-hosted original photo/video backup with an ASP.NET Core backend and a native
[iOS client](ios/README.md). Implementation is on `feature/mvp-foundation`;
[the execution plan](specs/004-mvp-execution-plan.md) records the wider roadmap.

**License:** proprietary; use requires explicit written permission from the
copyright holder. This is **not the Unlicense**. Third-party dependencies,
models and test media retain their own licenses; see [LICENSE](LICENSE).

## What is implemented

- Known-user Keycloak authentication; real JWT validation and immediate platform
  disablement checks. No public registration or application password grant.
- A separate, localhost-only administration console for known users, personal
  libraries, membership enablement, and passwordless enrollment invitations.
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
- Optional [owner-private face service](face-inference/README.md): local CPU
  detection/embeddings, stable person clusters, names, aliases, reversible
  merges/splits and manual negative matches. A transactional Library outbox
  automatically queues eligible committed primary photos independently of backup.
- Renewable, persisted 30-day retention holds with fresh original rehashing for
  eligible phone cleanup. No application endpoint deletes committed originals.
- Shared OpenTelemetry logs/metrics/traces and Grafana/Prometheus/Loki/Tempo,
  including propagation through verification, the outbox, and projection.
  The private Python administration service exports all three signals through
  the same Collector and propagates trace context into the administration API.
  Provisioned operational dashboards and alert rules cover worker liveness,
  storage headroom, verification, publication backlogs, and dead letters.

This is a functional MVP, **not certification of every north-star requirement**.
Native sharing/People UI, semantic search, APNs, Android, HA, and multi-host
workload/network isolation remain unfinished. Face analysis currently supports
JPEG/PNG/WebP, not HEIC/video. See the iOS documentation for supported resource restoration and
device-only acceptance checks; a simulator build does not certify Face ID,
background scheduling, or Photos deletion.

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
settings. Environment edits do not rotate credentials already stored in volumes.

| Local address | Purpose |
|---|---|
| `http://localhost:18080` | Backend API and `/v1/config` |
| `http://localhost:18082` | Dedicated administration console, username `admin` |
| `http://localhost:18081/admin/` | Keycloak provider administration, username `admin` |
| `http://localhost:18083` | Development-only enrollment email inbox (Mailpit) |
| `http://localhost:13000` | Grafana, username `admin` |

Use `KEYCLOAK_ADMIN_PASSWORD` from `.env` for both private administration consoles,
and `GRAFANA_PASSWORD` for Grafana. Do not share or commit them. PostgreSQL,
RabbitMQ and OTLP have no host-published ports. All development host ports bind
to loopback, not the LAN.

In the Nephos administration console, create a user and personal library, then
send a passkey enrollment invitation. Open the invitation from the local Mailpit
inbox in the browser/device that will hold the credential. Invitations expire
after 15 minutes. Configure a real SMTP provider in the private Keycloak console
for non-development enrollment; mailbox access is enrollment/recovery authority.
Do not expose Mailpit publicly. Existing foundation realms without SMTP can
configure `mailpit:1025`, sender `nephos@localhost`, in Keycloak.

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
History currently retains asset versions; this MVP has no committed-asset
deletion or history-compaction API.

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
validate real JWT/JWKS, PostgreSQL, immutable chunk retry, restart/resume,
verification failure, deduplication, authorization, original/ranged bytes,
previews, retention, paging, invitation delivery, and stored correlated telemetry.
The browser suite enrolls a real Keycloak passkey using Chromium's virtual
authenticator, signs in with Code+PKCE, verifies API access/disablement, and
exercises operator recovery. This is not a physical iOS passkey or real Photos
removal test. The edge suite exercises the actual Caddy route configuration
on a temporary loopback HTTP listener; it does not certify DNS or certificates.
The restore exercise pauses writers, restores isolated PostgreSQL/RabbitMQ/media
volumes, checks original bytes, complete manifests and frozen views against their
restored references, verifies a pending publication survives, and resumes the
source deployment. A separate disposable identity stack verifies actual Keycloak
production startup and proxy-aware HTTPS discovery without changing the live realm.
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
