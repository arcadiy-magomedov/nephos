# MVP Stack Decisions and Draft Execution Plan

## 1. Goal and status

Deliver an iOS-to-self-hosted-backend journey: sign in, upload original photos
and videos reliably, browse the complete gallery, retrieve individual originals,
enable automatic backup, and optionally remove verified backed-up phone copies.

This document records user-selected technologies and a proposed execution order.
Implementation has been authorized and started on `feature/mvp-foundation`.
This does not mean all MVP scope boundaries and supporting libraries have been
chosen. The production north star
remains [000](000-media-platform.md), with architecture in
[001](001-system-architecture.md), threats in [002](002-threat-model.md), and the
client contract in [003](003-mobile-client.md).

## 2. Confirmed requirements and technology choices

| Area | User decision |
|---|---|
| Backend API services | C# / ASP.NET Core |
| Metadata persistence | PostgreSQL behind service-owned repository interfaces |
| PostgreSQL access | Npgsql directly with explicit parameterized SQL in repository adapters; no Entity Framework or ORM |
| Media bytes | Mounted-volume storage adapter, not database byte columns |
| Authentication | Dedicated Keycloak service; ASP.NET Core JWT bearer validation |
| iOS | Swift with SwiftUI/UIKit and native platform integrations |
| Deployment | Docker Compose for the MVP and backend E2E environment |
| Background jobs/events | RabbitMQ; durable operation state remains in owning services |
| Observability | Centralized OpenTelemetry Collectors for logs, metrics, and traces from all application microservices |
| Telemetry storage and UI | Grafana dashboards, Prometheus metrics, Loki logs, and Tempo traces |
| Automatic backup | Independent opt-in setting; uploads existing and new accessible photos/videos |
| Automatic phone removal | Independent opt-in setting; initiates eligible removal after verified durable backup, subject to OS execution and consent requirements |

All application services use the shared Collector rather than separate telemetry
stacks. Grafana provides the common operator UI over Prometheus, Loki, and Tempo.
This is a self-hosted selection, not a requirement for Grafana Cloud.

Version selection must pin supported runtime, SDK, package, image, and database
versions together after compatibility checks. Provider selection does not prove
the specified enrollment/recovery flows or deployment behavior.

## 3. Scope proposal

### 3.1 In the requested MVP

- Authenticated intent/chunk/resume/finalize/status APIs with safe deduplication.
- Volume-backed original storage, integrity verification, references, and recovery.
- Service-owned PostgreSQL persistence and migrations.
- Authorized layered gallery retrieval and individual-original/ranged retrieval.
- Known-user authentication, private administration boundaries, and account checks.
- Minimum iOS setup/login, upload status, gallery/viewer, and the two automation
  settings. Original caches and transfer staging stay bounded.
- RabbitMQ processing with retry/idempotency, observable completion, and recovery.
- Centralized telemetry present from the first service, not deferred hardening.
- E2E evidence throughout; safety and authorization are not postponed to release.

Preview/metadata generation is supporting work for a usable gallery, not a
requirement to introduce AI. Unsupported media must remain honestly represented;
a preview or transcode is not proof that the original resource set was backed up.

### 3.2 Proposed deferrals, awaiting scope agreement

Android, semantic search, AI trash review, generic
drive/folder behavior, S3/Azure adapters, Swarm/Helm packaging, explicit offline
original pinning, and local-network auto-discovery can follow the first release.
These are proposals, not deletion of north-star requirements.

The user subsequently explicitly requested face-service implementation and real
internet-photo validation. An optional Faces API/worker and private local
inference service now implement owner-private detection, embeddings, clusters,
names and reversible corrections. Library supplies live source authorization and
a transactional publication outbox; JPEG/PNG/WebP/HEIC/HEIF primary photos are eligible.
Six licensed portraits are a small real-inference smoke set, not a representative
accuracy benchmark. HEIC decoding is server-side and never replaces an original;
the format-expansion migration queues eligible older HEIC/HEIF photos. Video
analysis and semantic/person combined search are still outstanding.
Native People/correction and known-user sharing screens are now implemented,
along with the approved media-first navigation and System/Light/Dark setting.
Server albums remain unavailable; the native Albums tab exposes libraries and
sharing without inventing album data. See `face-inference/README.md` and
the current [native feature inventory](../ios/README.md#remaining-features).

The custom platform administration UI and APNs delivery deserve explicit scope
decisions. Keycloak supplies identity administration, not library/storage
management. An existing provider console cannot be claimed as completion of the
dedicated platform console. Push is not necessary for correct foreground sync or
OS-scheduled backup and does not guarantee background execution.

## 4. Proposed deployable boundaries

Keep small, separately deployed services rather than hiding all backend work in
one API process:

| Component | Responsibility |
|---|---|
| Library API and library-owned projection workers | Logical assets/resource sets, membership, authorization, manifests, deltas, operation outcomes |
| Storage/upload API | Intents, chunks, sealed upload state, provider abstraction, references, original retrieval and cleanup |
| Verification/media workers | Queued integrity verification, bounded metadata/preview processing, revision-fenced results |
| Keycloak | Passkey/login/enrollment, token issuance/refresh, provider administration |
| PostgreSQL | Isolated service-owned databases/roles on one MVP server; no cross-service table writes |
| RabbitMQ | Durable work queues/events with publisher confirms, acknowledgements, and bounded retry/dead-letter behavior |
| Shared OpenTelemetry Collector | Private OTLP ingestion and centralized logs/metrics/traces pipelines |
| Telemetry stores/dashboards | Prometheus, Loki, and Tempo with Grafana; private access and bounded retention |
| HTTPS ingress | Public application/login routes, separate private administration and observability routes |

Workers receive narrow job authority, not unrestricted provider/database access.
Repository adapters use Npgsql connections/commands and explicit parameterized
SQL. Keep connection pooling, transaction boundaries, and row mapping inside the
persistence implementation; do not expose provider types in domain contracts.
No Entity Framework or Dapper dependency is required. The initial foundation
uses a small runner for embedded, versioned SQL with checksums, transactions,
and an advisory lock. Reevaluate this implementation before complex upgrades;
adopting a migration library later must preserve the applied migration history.
Repository abstractions do not imply a distributed transaction across services.
Use outboxes and recoverable state machines at publication boundaries.

The shared Collector is the MVP topology, not a high-availability claim.
Collection can scale behind a common endpoint later. Export failure must not
become upload failure; operation/audit journals are independent of telemetry.

## 5. Execution milestones

Each milestone ends with a runnable vertical slice and evidence through actual
service APIs. No standalone component is considered complete merely because it
builds. The sequence below is proposed; dependency links reflect real prerequisites.

| Milestone | Depends on | Deliverable and exit evidence |
|---|---|---|
| M0: Decisions and feasibility probes | None | Resolve the next blocking choices below; demonstrate Keycloak/iOS passkey login and the supported iOS background/removal behavior before promising unattended automation |
| M1: Observable, authenticated skeleton | M0 | Compose provisions services, PostgreSQL, RabbitMQ, Keycloak, Collector, and selected telemetry destinations. Swift app configures HTTPS URL and signs in. Protected API rejects invalid tokens/membership. Logs, metrics, and a trace are queryable centrally |
| M2: One original end to end | M1 | iOS selected-item upload traverses intent, numbered chunks, queued verification, durable original/reference/asset publication, and authorized download. Compare retrieved bytes with the source; follow HTTP and queue work in telemetry |
| M3: Reliable uploads and resource sets | M2 | Resume interrupted uploads, deduplicate safely, handle changed sources and complete compound resource manifests. Persist client/OS task mappings; partial backups never become removal-eligible |
| M4: Usable remote gallery | M2 | Metadata/previews, layered chronology, lazy pages, individual viewing/ranged retrieval, and durable delta catch-up. Exercise two clients and stable anchors; do not return an unbounded entire-library payload |
| M5: Automatic backup | M3, M4 | Discover existing/new permitted device media, queue bounded exports/transfers, respect resource policy, and expose real completion/deferred/error status. No permanent original cache or immediate reupload of deliberately removed remote revisions |
| M6: Opt-in phone cleanup | M5 | Fresh complete backup evidence and existing retention safeguards drive removal eligibility. Honor iOS dialogs/permissions, maintain server copies, and expose pending/partial/cancelled outcomes without claiming immediate physical savings |
| M7: Release and restore exercise | M6 | Reproducible install/upgrade/backup/restore, private route verification, supported-device E2E, operational dashboards/alerts, low-storage/broker/collector failure behavior, and a documented media/platform support matrix |

M4 can proceed alongside M3 once M2 establishes the asset/retrieval contracts.
No implementation concurrency is assumed until staffing and work boundaries are
known. Timing estimates should follow M0, not be invented before integration
uncertainties are resolved.

### 5.1 M0 probes and concrete outcomes

- Provision a known user, enroll/login with a passkey using iOS OIDC Code+PKCE,
  recover credentials, and disable membership. Record required Keycloak flow
  configuration and any gap against R08/R09.
- Exercise PhotoKit export, background transfer, limited access, and local
  removal on a supported real device. The requested auto-removal setting does
  not waive system confirmation. Report platform constraints before enabling it.
- Select representative JPEG/HEIC/video and compound-resource fixtures. Define
  what can be restored and which incomplete/unsupported items cannot be offloaded.
- Verify the selected telemetry destinations and OTLP integration for all three signals.
  Define a central endpoint and service identity convention.

### 5.2 M1 observability contract

Instrument ASP.NET Core requests, outbound HTTP, supported PostgreSQL operations,
RabbitMQ publish/consume, and application activities. Correlate structured logs
with trace/span IDs; use bounded metric dimensions. Carry trace relationships
through durable outbox/job boundaries rather than assuming one live request.

The central Collector exposes a metrics exporter for Prometheus to scrape,
sends logs to Loki through OTLP/HTTP, and sends traces to Tempo through OTLP.
Grafana queries these backends with provisioned data sources and correlation
links. Backend storage modes, retention, sampling, and disk/memory budgets must
be validated for the Compose host; selection does not imply unlimited storage.
Include available infrastructure telemetry through appropriate receivers/exporters.
Private operator dashboards must support finding a failed operation by its
correlation context across services. Missing spans because of sampling are not
proof of missing work; authoritative operation state remains queryable.

Apply R34 redaction, private access, batching, queue limits, and failure
visibility. Verify an unavailable telemetry backend neither blocks the API nor
causes unlimited buffers. Real-backend signal queries, not a collector's accepted
request alone, demonstrate observability integration.

### 5.3 Minimum iOS presentation

Proposed screens: connection/login, gallery/viewer, backup status, and settings.
Settings expose the independently selected automatic-backup and automatic-removal
toggles. Phone cleanup status identifies waiting-for-confirmation, ineligible,
completed, and failed items. Exact layouts, defaults for network/charging rules,
and the supporting local persistence library remain open.

Show pending uploads separately from committed server gallery entries. Local
source identifiers, remote asset IDs, and transient preview caches are different
concepts. Preserve durable upload/review mappings when evicting media caches.

## 6. Remaining choices to weigh

Do not mistake these options for selected dependencies:

| Decision | Options worth comparing | Needed before |
|---|---|---|
| Telemetry operation | Storage modes, retention, sampling, resource budgets, and alert rules for the selected Grafana/Prometheus/Loki/Tempo stack | M1 |
| Database migration upgrades | Validate the initial versioned-SQL runner against upgrade/rollback needs; compare established tooling if it becomes insufficient; no EF migrations | M2 |
| RabbitMQ integration | RabbitMQ .NET client; messaging framework with explicit current licensing, outbox, and serialization review | M2 |
| Ingress/TLS | Caddy, nginx, or another already-operated reverse proxy | M1 |
| iOS OIDC and local persistence | Established OIDC client versus carefully scoped platform integration; SQLite-oriented library versus platform persistence | M1/M3 |
| Media tools | Compatible metadata/thumbnail/video tooling with isolation, licensing, and format-support evidence | M4 |
| Administration scope | Private provider console plus scoped platform management tooling; minimal dedicated platform UI | M1/M7 |
| Mobile notification scope | HTTPS catch-up/OS scheduling first; APNs integration with explicit build/sender authority | M4/M5 |

Use the selected stack for focused comparisons rather than reopening language or
database decisions at every milestone. Choose implementation libraries when their
contract is understood; do not infer them solely from framework defaults.

## 7. Acceptance and release scope

Trace MVP work to backend R01, R03-R06, R08-R16, R24-R29, R31-R32, R34 and the
applicable client C01-C09, C12-C15, C18-C21 contracts. R10 administration,
R30 notifications, C10 search, and other partially scoped areas require explicit
feature-level inclusion/deferral rather than claiming whole-requirement coverage.

Unit/property tests precede deterministic protocol and state-machine changes
where useful. Adapter tests use real PostgreSQL and the actual mounted-volume
semantics. Integration/E2E tests use real RabbitMQ and Keycloak; client tests
include supported real-device evidence. Test containers alone cannot certify iOS
execution, Photos permission, or deletion behavior.

The shipped profile documents supported formats/OS versions, resource budgets,
retention/recovery behavior, enabled features, and known limitations. Selected
technology does not relax the north star's security and correctness contracts.
The implementation now includes the end-to-end media backend and native iOS
work. Device-only qualification and the release/restore exercise must not be
confused with passing local backend/simulator checks.

## 8. Implementation progress

Implemented on `feature/mvp-foundation`:

- .NET solution, shared authentication/telemetry setup, separate Library and
  Storage service hosts, and Npgsql-backed membership-scoped library listing.
- Versioned SQL migrations and separate owner/runtime database roles.
- Development-only Compose wiring for Keycloak, PostgreSQL, RabbitMQ, volume
  storage, ingress, shared Collector, and Grafana/Prometheus/Loki/Tempo.
- Signed-token API tests and a real-stack smoke runner covering authorization,
  database isolation at the API boundary, and stored telemetry.
- Idempotent intents, immutable numbered chunks, resumable status, sealed
  verification, content-addressed originals, explicit references, and cancellation.
- Separate verification/projection workers, a transactional outbox, durable
  RabbitMQ publication/acknowledgment, and cross-job trace propagation.
- Authorized bounded galleries, UTC timeline counts, previews, ranged originals,
  capture-date ordering, and persisted renewable 30-day offload holds.
- Dedicated private administration, known-user provisioning, personal libraries,
  enable/disable controls, and short-lived passkey invitations through SMTP.
- Native iOS implementation under `ios/`; its README records supported resources,
  exact build commands, and actual native/device verification status.
- Cold-backup/non-overwriting restore tooling and an isolated restore exercise
  for original bytes, all service databases, and queued unprojected work.
- Complete immutable compound manifests, hidden pending constituents, distinct
  logical references for same-byte resources in different sets, and whole-set
  ownership/integrity/retention evidence.
- Seven-day immutable gallery snapshots, frozen date counts/pages, serialized
  atomic delta batches, and invalidation on account access-generation changes.
- Operational dashboards and evaluated alert rules, separately identified worker
  telemetry, restricted publisher/projector identities, and production-mode
  identity/application startup in the HTTPS overlay.
- Browser acceptance using a virtual user-verified passkey: known-user invitation,
  enrollment, Code+PKCE login, API authorization, disablement, and operator recovery.

Local backend acceptance now exercises actual upload/retrieval, out-of-order and
duplicate chunks, API restart/resume, broker outage/recovery, corrupted input,
cross-user deduplication without hash-only disclosure, previews, pagination,
retention, disablement, private provisioning, and invitation delivery.

Explicit qualification/follow-ups:

1. Real-device passkey enrollment/recovery, PhotoKit/background/deletion behavior,
   signing/distribution, and a configured canonical HTTPS domain.
2. Device qualification of compound/edited restoration before expanding cleanup
   eligibility; archival completeness is not an edit-history reconstruction claim.
3. Multi-host identity/workload/network isolation and an operator-maintained
   independent backup destination. A single-volume retention hold is not an
   independent backup, even when local cold-restore checks pass.

Operational commands and current limitations are in [README](../README.md).

## 9. Current release evidence and remaining external gates

The backend and native implementation are present; the Compose application is
runnable. This is not a claim that the physical-device portions of M0/M7 passed.

| Area | Evidence |
|---|---|
| Backend | Locked restore, build, formatting and 24 .NET tests; real foundation/admin/media/resource-set/snapshot suites |
| Identity | Real browser invitation, user-verified virtual passkey, Code+PKCE, disablement and operator recovery; isolated production-mode Keycloak startup |
| Gallery/resources | Frozen counts/pages, atomic paged deltas, concurrent arrivals, account fencing, incomplete-set hiding, immutable manifests and complete retention |
| Native client | 20 deterministic tests, Debug/Release builds, signed simulator setup launch, expanded Swift-to-backend E2E, exact PhotoKit JPEG/video/Live Photo restoration round-trips |
| Operations | Six application-service heartbeats, including private Python administration; correlated central logs/metrics/traces, dashboards, evaluated alert rules and restricted broker credentials |
| Failure/recovery | API restart/resume, broker/Collector outage recovery, real low-capacity-volume admission rejection, private ingress isolation, cold restore of originals/manifests/snapshots/pending publication |

Native save-back supports singles and runtime-supported unedited Live Photos/
RAW+JPEG pairs; edited/archive sets export their complete verified resource bundle.
Automatic cleanup remains restricted to supported unedited singles. Compound
archival completeness does not authorize deleting the phone's compound original.

The repeated simulator qualification passed after correcting the probe to invoke
the production PhotoKit permission request before checking authorization. JPEG,
video and Live Photo restoration preserved every original's SHA-256/size and
the expected semantic/cleanup boundaries.

**Unpassed qualification:** physical-iPhone passkeys, background execution, Photos
consent/deletion and representative camera RAW restoration still require device
access. Production signing/distribution, a real canonical HTTPS hostname, and an
operator-controlled independent backup destination require deployment resources
that are not present in this workspace.
