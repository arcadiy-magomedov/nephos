# Self-hosted Media Platform Specification

## 1. Project definition

### 1.1 Purpose

Build a self-hosted media platform from scratch, starting with an Immich-like
photo and video library tailored to the owner's needs. The platform must later
support applications such as a Jellyfin-like media library and a personal books
library for an iOS client without rebuilding its shared backend capabilities.

The primary goal is to keep family photos and personal media on operator-owned
hardware while retaining the convenience of commercial cloud galleries: remote
access, complete-library browsing, reliable uploads, search, and sharing. Core
functionality must not require Apple iCloud, OneDrive, or another proprietary
cloud account/service. Cloud hosting and managed storage remain optional
deployment choices, not dependencies.

The backend provides storage, resumable uploads, access control, sharing, media
processing, face recognition, multimodal semantic search, and user-reviewed AI
cleanup suggestions for potentially unwanted media. Proven
infrastructure and ML components may be reused; "from scratch" does not mean
reimplementing identity protocols, storage engines, or ML models.

### 1.2 Architecture and operating environment

- Small, independently deployable microservices, not a modular monolith.
- Operator-deployed on home servers or cloud infrastructure, including managed
  Kubernetes such as AKS, without assumptions about physical disks, RAID,
  filesystems, or storage providers.
- Media storage hidden behind an abstraction supporting mounted volumes,
  S3-compatible object storage, and Azure Blob Storage.
- Deployment definitions for Docker Compose, Docker Swarm, and Kubernetes/Helm,
  including required dependencies.
- Publicly reachable user-facing endpoints, with administrator-managed users.
- A dedicated administration console reachable only through the deployment's
  authorized private network, never through the public internet. No specific
  network provider or VPN product is required.
- Database engines hidden behind service-owned repository/adaptor boundaries.
- Dedicated vector-search service and queue-driven, throttled processing.
- Versioned gallery manifests, retained snapshots, bounded media segments, and
  resumable deltas, with a real-time notification contract for connected clients.

### 1.3 Scope and specification status

The initial application is the photo/video backend. Native phone upload clients,
the end-user UI, cinema/TV applications, and books clients require separate design
specifications. Their future integration must be accommodated by this backend.

This document defines the production-grade north star, not an MVP. Resource
limits, history retention, recovery, and consistency are architectural contracts,
not reasons to silently weaken guarantees for an initial deployment. MVP scope
and implementation sequencing will be designed separately.

Section 2 records the requirements established during discussion. Section 3 maps
a proposed solution to every requirement. Technologies and policies explicitly
marked **open** or **proposed** have not been selected or approved.

Supporting documents:

- [001 - System architecture and flows](001-system-architecture.md).
- [002 - Design-time threat model](002-threat-model.md).
- [003 - Native mobile client draft](003-mobile-client.md).

## 2. Requirements

| ID | Requirement |
|---|---|
| R01 | Provide a backend for backing up, organizing, and serving photos and videos. |
| R02 | Support future media applications and domain plugins, including cinema/TV and a personal books library. |
| R03 | Implement the backend as small, independently deployable microservices. |
| R04 | Provide Docker Compose, Docker Swarm, and Kubernetes/Helm deployment options with dependencies, including managed Kubernetes environments such as AKS. |
| R05 | Abstract media storage behind provider-independent contracts supporting mounted volumes, S3-compatible object storage, and Azure Blob Storage; physical storage topology must not affect application logic. |
| R06 | Keep application logic database-engine agnostic through repository interfaces that hide persistence and retrieval details. |
| R07 | Implement vector search as a dedicated microservice; other components must not depend on its vector database or indexing implementation. |
| R08 | Deploy an authentication server supporting passwordless authentication, WebAuthn/passkeys, and device biometric login experiences such as iOS Face ID and Touch ID. |
| R09 | Admit only known, administrator-provisioned users; do not allow public registration. |
| R10 | Provide a dedicated admin web console for managing users, libraries, and system operations. |
| R11 | Make administration accessible only through an authorized private network, never through the public internet, independently of hosting environment or networking product. |
| R12 | Make user-facing services accessible from the public internet through a deployment-configured HTTPS ingress, without requiring a specific tunnel or networking provider. |
| R13 | Implement intent-based, resumable uploads with independently retryable chunks that may arrive out of order. |
| R14 | Deduplicate identical files using content hashes, supporting an upload shortcut when safe and avoiding duplicate permanent storage, including for large files. |
| R15 | Track who uploaded each logical asset and enforce ownership and access permissions independently of shared physical storage. |
| R16 | Track references to shared stored content so removing one user's asset does not delete another user's content. |
| R17 | Allow user A to share all their media or a selected subset with user B. |
| R18 | Let clients identify shared media and its provenance so it can be highlighted in the UI. |
| R19 | Recognize faces through clustering and provide editable person labels/names. |
| R20 | Let users mark separately recognized identities as the same person and preserve those corrections. |
| R21 | Generate multimodal embeddings for images and videos, with Gemma-based embedding models as the requested initial candidate. |
| R22 | Search photos and videos using free text and person names, including combined searches. |
| R23 | Support whole-library semantic re-embedding and reindexing when the embedding model changes. |
| R24 | Run CPU/GPU-intensive processing, including face recognition and embedding generation, through a durable queue and pub/sub model. |
| R25 | Throttle background work so processing and reindexing do not overwhelm the home server. |
| R26 | Keep native phone-client implementation out of the current backend scope while exposing the contracts those clients will need. |
| R27 | Provide layered year/month/day chronology responses with separate photo/video counts, lazy day-level media URIs and metadata, direct date jumps, and bidirectional infinite scrolling for millions of assets spanning 20+ years. |
| R28 | Preserve operator ownership and control of family photos and media, with a fully self-hosted deployment that does not require proprietary cloud services for core functionality. |
| R29 | Let clients incrementally reconcile cached chronology and media when backend data changes, including uploads, deletions from other clients, metadata/date edits, and sharing changes, without routinely rebuilding the entire local index. |
| R30 | Define a versioned, authenticated real-time client/API notification contract with reconnect, catch-up, backpressure, and polling fallback, without depending on a continuously connected client for synchronization correctness. |
| R31 | Make the entire system end-to-end testable at every stage; an architecture that prevents an E2E test of supported behavior is unacceptable. Prefer test-driven development where appropriate. |
| R32 | Apply least privilege, hostile-input isolation, artifact verification, privacy-scoped annotations, and security-preserving recovery across public APIs, internal services, asynchronous work, storage, and deployment. |
| R33 | Classify potentially unwanted photos/videos, including social-media memes/forwards, blurred captures, and temporary screenshots, and suggest cleanup with explanations and user control; classification must never automatically delete media. |

## 3. Solutions by requirement

### 3.1 R01 - Photo and video backend

Introduce a library service that owns logical media assets, libraries, metadata,
and access decisions. Store original media through the storage service and
generate previews and extracted metadata asynchronously.

An uploaded original becomes available after integrity verification and
authorization state are committed. Face recognition, semantic indexing, preview
generation, and cleanup classification have separate visible processing states;
they must not be prerequisites for accepting an otherwise valid original.

Provide complete-library browsing independently of semantic/person search, as
specified in R27. The library service must serve this experience even when ML or
the vector-search service is unavailable.

### 3.2 R02 - Future applications and plugins

Share backend capabilities for identity, blobs, uploads, grants, processing, and
search. Keep application-specific metadata in domain-owned models:

- Photos: albums, capture metadata, faces, and people.
- Cinema/TV: titles, seasons, episodes, playback state, and streaming workflows.
- Books: authors, editions, document metadata, and reading progress.

Use versioned APIs and events for extensions. Initially, extensions are trusted
first-party services/workers. Untrusted plugins, their sandboxing, and a public
plugin marketplace are **not established requirements**.

#### Follow-up: generic files and a drive-style library

Extend the platform to arbitrary files, with Photos as a specialized view of
eligible media rather than a separate upload silo. The Yandex Disk analogy is a
product model, not an assumption about its internal implementation. This is a
recorded follow-up, not an expansion of the current photo/video implementation
scope or a commitment to an S3-compatible public API.

The existing blob/upload layer is reusable, but a user-facing drive also needs
logical file identities, folders/namespaces, move/rename and overwrite/version
semantics, grants, quotas, trash, and synchronization. Immutable physical blobs
alone do not provide those behaviors.

**Open question: one upload entry point or domain-specific endpoints?**

| Approach | Trade-off |
|---|---|
| Shared upload-intent API with a typed destination | One resumable transfer contract for all files; destination authorization and publication must route to the owning domain |
| Domain-specific intent APIs over a shared upload service | Domain-specific validation is explicit; transfer/session mechanics remain shared rather than duplicated |
| Independent upload pipelines per application | Stronger isolation, but duplicates retry, quota, integrity, and lifecycle logic; needs a concrete justification |

**Recommendation, not yet selected:** share the upload-session/data-transfer
contract, preferably with one intent entry point. Bind each intent to an
authorized logical destination and its owning service, not merely a MIME type.
The owning domain validates and durably publishes the entry after verification;
workers run only for applicable, validated content and enabled features. Arbitrary
files must not be sent automatically through photo/face pipelines.

A shared entry point can still return multiple chunk/provider URLs. It does not
require one physical server or eliminate domain-specific APIs. Safe deduplication,
quota reservation, reference acquisition, retry/idempotency, and current
authorization at publication must apply consistently to every destination.

The follow-up must decide ownership between generic file entries and photo
projections, including whether one entry appears in both views, and the effects
of moves, edits, sharing, and deletion. Do not create independent file/photo
entries or extra ownership grants solely to populate a gallery. Cross-view
authorization, lifecycle consistency, unsupported-file handling, and failed
publication recovery require R31 E2E evidence before accepting this extension.

### 3.3 R03 - Microservice boundaries

Use the following proposed deployment units:

| Component | Ownership |
|---|---|
| Public gateway | Public routing, HTTPS integration, request limits |
| Authentication server | Identity, credentials, enrollment, login, sessions |
| Library service | Assets, grants, private cleanup reviews/protections, ordered mutation journal, gallery manifests/deltas, client synchronization, user-facing search orchestration |
| Storage/upload service | Upload sessions, chunks, immutable blobs, physical references, garbage collection |
| Face service/workers | Face observations, clustering, person identities, correction history |
| Search service/workers | Semantic indexing, model generations, vector retrieval, reindex orchestration |
| Curation service/workers | Cleanup assessments, model generations, scan orchestration |
| Media workers | Metadata extraction, thumbnails, previews, video processing |
| ML inference service/workers | Model execution behind controlled processing capacity |
| Admin console/backend | Private administration UI and orchestration of management APIs |

Supporting infrastructure includes a durable message broker, service persistence,
private media storage, and a vector database.

Services communicate through explicit APIs and durable events. No service writes
directly into another service's database. Expensive processing workers can scale
independently of user-facing APIs.

Gallery projection/publication workers are part of the library service's
ownership boundary and consume its ordered journal. A separately scalable
notification gateway delivers hints from published revisions; it does not own
assets, permissions, synchronization history, or independent business state.

```text
Public clients -> Public gateway -> Library / Upload APIs
                         |
                         +-------> Authentication endpoints

Authorized private network -> Private admin gateway -> Admin console/API

Library AssetReady -> Durable broker -> Media workers
                                    -> Face pipeline -> ML inference
                                    -> Curation pipeline -> ML inference
                                    -> Search pipeline -> ML inference
                                                       -> Vector database

Library search -> Search service
Library / workers -> Authorized storage APIs

Library journal -> Gallery projection/publication -> Snapshots + deltas
                                                -> Notification gateway
Clients -> HTTPS gallery/sync APIs
Clients <- SSE change hints through public gateway
```

### 3.4 R04 - Deployment packaging

Package the same versioned application images in three deployment targets:

- Docker Compose for a single host.
- Docker Swarm stack definitions.
- Helm charts for Kubernetes, including managed clusters such as AKS.

Include configuration for the authentication server, broker, databases, vector
engine, storage, persistent volumes, migrations, health checks, secrets, and
optional GPU access. Allow externally managed dependencies without requiring them.

For filesystem-backed media storage, mount a configurable persistent volume into
the storage service: a Compose volume/bind mount, a Swarm volume, or a Kubernetes
PersistentVolumeClaim. For S3/Azure, configure the adapter's endpoint,
bucket/container, and credentials instead; do not require mounting an object
store as a filesystem.

Volume provisioning, replication, backups, and placement are deployment concerns.
Swarm/Kubernetes scheduling must respect volume accessibility: a node-local volume
does not become shared or replicated merely because an orchestrator manages it.
Resumed uploads must reach their durable staging data after restarts/rescheduling.

These deployment formats are separate artifacts, not assumed to be
interchangeable. Validate their network exposure and resource controls
independently. Initial home-server deployments can use one instance per service;
containers on one machine do not provide host-level high availability.

### 3.5 R05 - Provider-independent media storage

The storage/upload service owns a storage interface and provider-specific
adapters. Other services use logical blob identifiers and authorized storage APIs,
never host paths, bucket/container names, or provider SDKs.

```text
Application services -> Storage/upload API -> Storage interface
                                             |-> Mounted-volume adapter
                                             |-> S3-compatible adapter
                                             +-> Azure Blob adapter
```

The interface covers upload creation, staging numbered parts, listing accepted
parts, completion/abort, streaming and ranged reads, object metadata, and
idempotent deletion. Keep source media and generated derivatives behind the same
abstraction. Provider locations and upload handles are internal adapter details.

Normalize integrity verification, durable completion, retry behavior, and error
semantics across adapters. Do not assume every provider supports filesystem
renames, identical checksum APIs, or the same multipart protocol. Use shared
contract tests to establish equivalent externally observable behavior.

Select the adapter through configuration without changing domain logic or client
contracts. A live provider switch additionally requires controlled data migration
and validation; a configuration change alone does not move existing media.

The owner's home-server disk arrangement is deployment context, not a system
requirement or an implementation prerequisite. Resource budgets remain
configurable for small servers, including CPU-only operation. Backup/restore must
cover media, service databases, and identity state regardless of storage backend.

### 3.6 R06 - Database-independent persistence

Use service-local repository interfaces and database-specific adapters:

```text
Transport / jobs -> Application logic -> Repository interfaces -> DB adapters
```

Domain/application logic must not expose ORM entities, database query builders,
SQL dialects, or database-specific result types.

Prefer operations aligned with domain behavior, such as
`findAccessibleAssets`, `recordUploadPart`, and `mergePeople`, rather than relying
only on a generic CRUD abstraction.

Define required guarantees for each operation: uniqueness, atomic state changes,
optimistic concurrency, ordering, pagination, and conflict/error behavior. A
unit-of-work abstraction covers atomic changes within a service, including its
outbox where required. Cross-service operations use recoverable workflows rather
than distributed database transactions.

Keep migrations, query optimization, and indexes inside adapters. Run common
contract tests against every supported adapter. An engine that cannot satisfy
required semantics is unsupported rather than silently weakening correctness.

The supported engine matrix remains **open**. Every supported adapter must meet
the same correctness contracts and its declared performance profile; supporting
an engine must not weaken the north-star behavior. Implementation sequencing is
outside this specification.

### 3.7 R07 - Dedicated vector-search microservice

The search service owns embedding configuration, semantic index generations,
vector-database adapters, similarity retrieval, and reindex workflows.

Expose domain-level operations to index/remove assets, search using text and
supported filters, and start/inspect a library reindex. Return asset identifiers
and matching video timestamps, not database-specific objects.

Other services must not know the vector engine, embedding dimensions, distance
metric, physical index layout, or database SDK. The library service remains the
authorization authority.

Support permission-aware candidate filtering through search contracts and
recheck authorization before returning results to clients. Handle stale
permission projections safely. Candidate pagination must allow retrieval of
enough authorized results instead of filtering a single fixed top-K set and
silently truncating the result set.

The vector engine remains **open**. Replacing it changes search-service adapters
and deployment configuration, not application contracts.

### 3.8 R08 - Passwordless identity and biometrics

Use a deployed identity provider supporting OIDC and genuine passwordless
WebAuthn/passkey login, not only WebAuthn as a second factor.

Face ID and Touch ID unlock a device-held credential. The backend verifies a
signed challenge; it does not receive or store the user's biometric data.
Require authenticator user verification for passwordless login.

Support multiple credentials, revocation, and a controlled recovery process.
Reserve a stable HTTPS authentication domain and relying-party configuration.
Future native clients use Authorization Code with PKCE; native passkey
integration may additionally require platform/domain association configuration.

The provider must demonstrate closed provisioning, passwordless enrollment,
credential management, and recovery. Password login is disabled; there is no
password fallback that weakens the passkey-only policy.

An administrator-provisioned account starts disabled and can enroll only with an
account-bound, short-lived, single-use activation ceremony. Activation is
delivered through the account's pre-verified out-of-band channel; the secret is
never returned by a public API or written to ordinary logs. The ceremony binds
the intended account, origin/relying party, and expiry, and is invalidated on
use, cancellation, or replacement.

Recovery uses two explicit paths:

1. A user may use one of a finite set of high-entropy, single-use recovery codes
   created at passkey enrollment. Only verifier hashes are stored server-side;
   codes are displayed once and the user is instructed to keep them offline.
   Successful recovery consumes the presented code, invalidates all remaining
   recovery codes and existing sessions, revokes the previous passkey set, and
   requires fresh passkey enrollment. Notify the account through its verified
   channel.
2. If all codes are unavailable, recovery requires an administrator in the
   private console, fresh passkey authentication, verified out-of-band identity
   confirmation against the pre-registered account channel, and a reasoned,
   audited operation. The reset requires new passkey enrollment and immediately
   revokes every prior passkey, recovery code, refresh token, session, and
   outstanding activation. Notify the account through its verified channel. If
   out-of-band identity cannot be verified, recovery is denied; there is no
   helpdesk-only or knowledge-question bypass.

Recovery never enables a disabled account or changes application membership.
Credential addition and recovery are visible to the account owner through the
verified channel. Authentik and Keycloak remain candidates only until they
demonstrate these behaviors; provider limitations do not weaken the contract.

### 3.9 R09 - Administrator-provisioned users

Disable public signup, including registration APIs and external identity flows
that would admit unknown users automatically.

The administrator creates a known user through the private admin console. Its
backend provisions the identity through a narrowly scoped identity-provider
management API and coordinates application membership with a retryable,
auditable workflow.

Account activation and passkey enrollment must be bound to that provisioned user.
Authentication succeeds only for permitted identities; application access also
requires enabled membership. Recovery must not create an alternate public
registration path.

Provisioning is an idempotent state machine. Until identity, membership, and
activation binding agree, the account cannot access media or administer the
system. Partial failures remain disabled and reconcile or roll back; retrying
does not create a second identity or reusable activation.

### 3.10 R10 - Dedicated administration console

Provide a separate admin web application and backend for users, libraries,
membership, quotas, sharing policy, processing status, failures, and operational
controls.

Management changes go through the owning service's API; the admin backend does
not directly edit service databases. Require administrator authorization,
appropriate recent authentication for sensitive actions, CSRF protection where
applicable, and audit records.

### 3.11 R11 - Private-network-only administration

Expose administration through a private gateway reachable only from configured,
authorized private networks. This is an environment-independent boundary, not
host-loopback-only access or a dependency on the owner's home network.

For example, a home deployment may use a LAN and Tailscale; an AKS deployment may
use a private ingress/internal load balancer reachable through an Azure virtual
network and an operator-managed VPN or equivalent private connection. These are
deployment choices, not application requirements.

The public gateway and any public tunnel upstream must have no administrative
routes. Restrict the authentication provider's own administration endpoints by
the same boundary.

Use private listeners, routing, firewall/network policy, and access controls
appropriate to the deployment. Do not publish an internet-facing administrative
endpoint and rely on login or a source-IP allowlist as a substitute for private
reachability. DNS names or hidden routes alone are not security boundaries.
Verify exposure separately for Compose, Swarm, and Kubernetes, including cloud
load-balancer and ingress configuration.

Private-network access is necessary but not sufficient: users must still
authenticate and possess administrator permissions.

### 3.12 R12 - Public user-facing access

Expose required user APIs and login endpoints through deployment-configured
HTTPS ingress. A reverse proxy, cloud ingress/load balancer, or public tunnel can
provide this boundary without changing application logic. Tailscale is optional;
private VPN connectivity alone does not satisfy public reachability.

Keep databases, brokers, vector engines, storage management, ML endpoints, and
internal service APIs private. Publicly reachable media endpoints still enforce
user authentication and authorization; anonymous sharing is not an established
requirement.

Upload and download URLs must resolve and work from outside the private network.
If storage remains private, use an authorized streaming data endpoint rather
than returning a presigned URL with an unreachable internal hostname. Evaluate
ingress bandwidth and large-video behavior before selecting the ingress approach.

The same HTTPS ingress supports the R30 notification stream. Configure streaming
without response buffering, compatible idle timeouts, and bounded connection
limits. Notification gateway restart or replacement must not require sticky
sessions to recover synchronization state.

### 3.13 R13 - Resumable, out-of-order uploads

Implement a provider-independent upload-session protocol. Storage adapters map
it to the backend's mechanism: staged parts on a mounted volume, S3 multipart
upload, or Azure block-blob staging and commit. Do not require S3 semantics in
application logic or couple the client contract to an individual storage vendor.

1. Client sends an authenticated upload intent with destination library, size,
   idempotency key, and optional whole-file hash.
2. Server validates permissions and quota, then either performs authorized reuse
   or creates a session.
3. Server returns session details, part sizing, expiration, and upload URLs.
4. Client uploads numbered parts independently and in any arrival order.
5. Client retrieves accepted-part state after interruption and retries missing
   or failed parts. Expired upload URLs can be refreshed.
6. Client requests finalization using the complete part manifest.
7. Server assembles, verifies, and publishes the asset before announcing it as
   ready for downstream processing.

Validate part boundaries, lengths, checksums, and manifest completeness. Protect
part replacement/finalization against conflicting concurrent requests. Persist
session state, make finalization retryable, and clean up expired incomplete
uploads and quota reservations.

A logical upload session replaces the requirement for one server-local temporary
file. Temporary parts/objects remain private until verified and use durable
staging appropriate to the selected adapter. An authorized upload endpoint can
stream parts to any adapter; provider-specific direct-upload URLs are an optional
optimization, not a required capability exposed in domain logic.

### 3.14 R14 - Content deduplication and safe upload shortcuts

Use a verified whole-file cryptographic hash, initially proposed as SHA-256, with
size and algorithm metadata to identify canonical immutable blobs. Verify bytes
server-side before accepting a client-supplied digest as authoritative.

Small files can supply the hash with the upload intent. Large files can also
supply a full hash to enable an early shortcut, or omit it and deduplicate after
upload verification. A sampled hash cannot establish whole-file equality.
Provider ETags, including multipart ETags, are not treated as whole-file SHA-256
values.

Return an immediate asset reference only when reuse is already authorized.
Knowledge of a hash must not grant access to another user's private bytes or
reveal their existence. If the caller lacks authorized reuse, require upload and
verification before attaching their own asset to an existing blob.

This deliberately restricts the hash shortcut to protect privacy. A shortcut
across private users would require a separately designed proof-of-possession
protocol.

Concurrent uploads of identical content converge through atomic canonical-blob
registration. Reconcile redundant temporary objects and incomplete finalization
after crashes. Deduplication scope (library, household/workspace, or server-wide)
remains **open**, including its privacy and encryption implications.

### 3.15 R15 - Logical assets, upload provenance, and access

Separate these concepts:

| Entity | Meaning |
|---|---|
| Blob | Immutable verified bytes and physical storage metadata |
| Asset | A logical library entry referencing a blob |
| Upload provenance | Actor, session, and source information for creating an asset |
| Grant | Permission to perform operations on assets or libraries |

Two users can own distinct assets referencing one blob. Their filenames,
organization, metadata, and permissions can differ.

Use roles for broad capabilities and resource grants for specific access.
Identity-provider roles do not replace media-level authorization. Physical
deduplication never implicitly shares media.

### 3.16 R16 - References and safe deletion

The storage service owns physical blob references and deletion state. Library
asset creation/deletion coordinates reference acquisition/release through
idempotent operations and durable events.

Acquire a durable reference or temporary hold before publishing an asset.
Release it only through a recoverable workflow. Authoritative reference records,
not an uncoordinated numeric counter, establish whether content remains in use.
A cached reference count is an optimization.

Garbage collection uses a grace period and coordinated state transitions so
reference creation cannot race with physical deletion. Account for active
uploads, processing holds, derivatives, and retention.

Periodic reconciliation detects orphaned objects, pending reference operations,
and stale holds. Deleting one asset or revoking one share must not remove bytes
required by another asset.

R33 cleanup moves assets to recoverable trash before final deletion. Trashed
assets retain references through the advertised recovery deadline; expiry and
restore must be fenced against each other before reference release and GC.

### 3.17 R17 - Whole-library and selected-media sharing

Represent shares as grants from an owner to another known user:

- Whole-library grant: **proposed** to include current and future media.
- Selected-media grant: covers an explicit set of logical assets.

Dynamic album/collection sharing can be added later but is not needed to satisfy
the initial requirement.

Sharing does not transfer ownership or create a second upload. Independently
uploading the same bytes creates an independently owned asset, unaffected by
revocation of someone else's share.

**Proposed policy:** read-only sharing without resharing. Whether edit,
delete, download, or resharing permissions are configurable remains **open**.

### 3.18 R18 - Shared-media provenance in API responses

Return structured ownership and access-source information, including owner,
sharer, effective permissions, and applicable access paths such as direct or
library sharing. Support multiple simultaneous grants rather than assuming one
`shared_by` value is sufficient.

Clients can highlight shared assets without inferring ownership from storage
identifiers. Revoking one grant preserves access supplied by another valid grant.

Apply access decisions to originals, thumbnails, face crops, search results, and
video segments. Direct download URLs, if used, require bounded expiry; immediate
per-request revocation requires an authorization-checking data gateway. Previously
downloaded copies cannot be revoked.

### 3.19 R19 - Face recognition, clustering, and names

Keep separate records for:

- Face observations: asset/frame, bounding box, timestamp, quality, embedding,
  and model/preprocessing version.
- Generated clusters: algorithm-produced similarity groups.
- People: stable user-managed identities, names, and optional aliases.

Process photos and sampled video frames asynchronously. Use face-specific
embeddings rather than assuming semantic media embeddings identify people.
Quality thresholds, clustering algorithms, frame sampling, and matching
thresholds remain implementation choices to validate.

Person labels and corrections are annotations, not properties of a deduplicated
blob. They are private to the annotating user's library view by default.
Recipients of shared assets do not inherit the owner's labels, aliases, face
clusters, merge decisions, or negative matches. A recipient may create their own
annotations over media they can access. Sharing annotations requires a separate,
explicit `view_person_annotations` grant; annotation-edit permission is separate
and never implied by media viewing or label viewing.

Authorization applies consistently to names, suggestions, identity resolution,
face observations/crops, search filters/results, and merge/correction history.
Internal reusable detections/embeddings may be shared only as non-user-facing
processing data; no label or identity association crosses annotation scopes
without the explicit grant. Revocation removes the annotation-derived view and
invalidates affected cached search/gallery state without deleting another
principal's corrections.

### 3.20 R20 - Manual identity merges and correction preservation

When clusters represent the same person, associate them with one stable person
identity. When existing people are merged, retain correction history and
redirects sufficient to undo mistakes.

A merge does not require retraining the face model. Preserve manual assignments,
merge decisions, and explicit negative matches independently of generated
clusters so reprocessing cannot silently erase them.

Avoid an irreversible union-only data structure. Support correcting wrongly
grouped faces as well as joining fragmented groups. Use multiple representative
embeddings for future matching rather than relying solely on a single centroid.

### 3.21 R21 - Image and video semantic embeddings

Use a multimodal model capable of placing text, images, and video representations
in a compatible semantic space. EmbeddingGemma 2 is the requested initial
candidate, subject to local benchmarking and runtime verification; it is not a
hard dependency exposed to other services.

Generate image embeddings and timestamped video-segment embeddings. Video
segmentation, sampling, and optional summaries must be versioned so brief
relevant moments are not lost in a whole-video representation.

The search service owns model and preprocessing configuration; ML workers execute
the jobs. Record model revision, preprocessing revision, source revision, and
index generation with each result.

Images, videos, metadata, archives, and model files are untrusted inputs even
after integrity/hash verification. Parsers, decoders, transcoders, and model
loading execute without service, host, provider, or administrator credentials.
Do not load executable model formats or custom code from unverified sources.
Detailed isolation and artifact requirements are in R32.

### 3.22 R22 - Combined semantic and person search

Resolve a person name to an authorized stable person identity, then combine that
filter with semantic retrieval. Names are not unique identifiers; handle
ambiguity rather than silently selecting a person.

For example, a query for "Alice at the beach" combines Alice's face associations
with semantic relevance to a beach scene. An explicit person filter plus free
text is the proposed initial API; natural-language name extraction can be added
without changing the identity model.

Compose face, library, and semantic-search results through service contracts.
Enforce current asset permissions before returning results, while accounting for
filtered-search recall and pagination.

Text-query embedding is also intensive processing. Route it through a bounded
interactive queue/lane with deadlines and reserved inference capacity so it does
not wait behind background reindexing.

### 3.23 R23 - Whole-library embedding migrations

Changing the semantic embedding model triggers full re-embedding and reindexing
of every applicable asset/segment in the affected library. Rebuilding a vector
database's physical index alone is insufficient.

Create an explicit generation tying together model, preprocessing, dimensions,
and indexing configuration. Query embeddings must match the searched generation;
never mix incompatible representations.

Track uploads, modifications, and deletions during rebuilding, and switch the
active generation only after the new one is consistent and ready. Report progress
and failures through administration.

Keeping the previous generation searchable during the rebuild is a proposed
availability option, subject to home-server capacity. Face-model replacement is
a separate migration and must preserve manual identity corrections.

### 3.24 R24 - Durable pub/sub and queued processing

Use durable events to fan out work to independent pipelines and competing
consumers to distribute jobs within each pipeline:

```text
AssetReady event -> Media-processing queue -> Media workers
                -> Face-analysis queue    -> Face workers
                -> Semantic-index queue   -> Search pipeline workers
                -> Cleanup-analysis queue -> Curation workers
```

All CPU/GPU-intensive work, including face processing, cleanup classification,
embedding generation, transcoding, bulk integrity verification, and
clustering/reindexing jobs, uses bounded queued execution. Network handlers may
stream data and perform bounded protocol work, but must not launch uncontrolled
processing.

The broker carries identifiers and processing parameters, not media bytes.
Workers retrieve media through per-job, narrowly scoped internal access issued by
the owning service. Private-network presence or possession of a broker message
alone never authorizes storage reads, metadata writes, or reference changes.

Each service and worker pool has an authenticated workload identity. Broker
producers and consumers have topic/operation ACLs; service-to-service calls use
authenticated transport and audience-checked workload credentials. A job grant
binds its job ID, input asset/blob revision, permitted operation, destination
service, model/preprocessing generation where relevant, expiry, and attempt.
Workers cannot select arbitrary input paths, commands, model sources, output
targets, or user permissions.

The owning service validates every result against current object state and the
job's expected revision/generation before commit. Deleted assets, cancelled jobs,
superseded attempts, and revoked workloads cannot publish results. Workers cannot
grant access, modify identity membership, or release permanent blob references.

Use at-least-once delivery with idempotent processing keys based on content
revision, task type, model/preprocessing revision, and generation. Acknowledge
only after outputs and processing state are durable. Use an outbox or equivalent
reliable publication mechanism at service boundaries.

Retry transient errors with backoff. Expose exhausted jobs through dead-letter
queues and administrative retry controls. Handle cancellation, deleted assets,
and stale generations without publishing obsolete outputs. Broker selection is
**open**.

### 3.24.1 Untrusted processing isolation

Treat every uploaded media file and derived archive/container as hostile,
regardless of MIME type, extension, or verified checksum. Run parsing, metadata
extraction, thumbnailing, transcoding, face detection, classification, embedding,
and model loading in a constrained worker sandbox. Implement it using an
appropriately hardened container, process sandbox, or stronger isolation runtime;
the selected mechanism must satisfy the following invariants:

- Non-root identity, read-only input, and a narrowly scoped output location.
- Drop unnecessary capabilities and apply a restrictive syscall policy. A
  deployment that cannot provide equivalent system-call confinement is not
  certified.
- No host/container-runtime socket, host filesystem, service database, broker
  administration, identity-provider, admin-console, or cloud-provider
  credentials.
- No ambient access to other assets. Inputs are granted per job and read-only.
- Default-deny network egress; permit only explicitly required service endpoints.
  Untrusted media metadata cannot select a URL, path, or destination to fetch.
- CPU, memory, process, file-size, decoded-pixel/frame/duration, output-size, and
  wall-clock limits with cancellation and bounded cleanup.
- No executable deserialization or unverified custom code/model loading.
- Outputs are treated as untrusted data, schema/size checked, and committed only
  by the owning service after revision and authorization checks.

Inference requiring a GPU follows the same data/credential and job-authority
boundaries. GPU device access is a capability and does not grant host,
provider, or unrelated media access. If a platform cannot provide the required
isolation, that deployment must fail closed or use a stronger isolation runtime;
it must not silently run hostile parsing with broad service privileges.

Image/runtime artifacts are pinned to immutable digests and accepted only after
signature/provenance or trusted digest verification against an operator-managed
trust root. Model weights are pinned and integrity-checked before loading.
Restrict artifact origins and update authority. Workers mount verified model
caches read-only; a separate trusted update lifecycle refreshes them. Production
processing does not download or execute arbitrary artifacts at job time. Keep
verified weights usable offline. Maintain software bills of materials and a
controlled update/rollback path.

### 3.25 R25 - Resource budgets and backpressure

Queueing is not sufficient on its own. Combine:

- Per-task worker concurrency and bounded prefetch.
- Shared CPU/GPU admission budgets across worker pools and inference processes.
- Container CPU/memory limits and appropriate I/O controls.
- Bounded batches and incremental scheduling for large reindexes.
- Priority/fairness between interactive work, new uploads, and bulk maintenance.
- Administrative pause/resume and configurable processing limits.

Reserve capacity for user-facing requests and interactive query embedding.
Avoid unbounded job creation or retry loops. Define overload responses and
deadlines instead of accepting work that cannot be serviced within configured
bounds.

Show queue depth, job age, active work, failures, and processing progress in the
admin console. Exact resource limits and scheduling policy remain **open** until
hardware and library size are known.

### 3.26 R26 - Future native client contract

Keep native application implementation in a separate specification. Provide
stable, versioned contracts for:

- OIDC login and session renewal.
- Upload intent, authorized reuse, chunk upload, resume, and finalization.
- Library discovery, chronology navigation, direct date jumps, bidirectional
  infinite-scroll pages, asset retrieval, processing status, search, and
  face/person operations.
- Versioned hierarchy bootstrap, day-page loading, and resumable change
  synchronization for cached gallery state.
- Logical asset/date anchors, atomic revision transitions, and the R30
  notification/reconnect protocol.
- Sharing, effective permissions, and provenance.
- Backend capability/identity discovery and optional LAN advertisement.
- Authorized, minimal, paginated known-user recipient discovery; no client access
  to identity-provider administration.
- Complete original-resource manifests and durable backup evidence, including
  compound media where supported. Per-file uploads are composed into a logical
  asset through a recoverable workflow; incomplete resource sets are not complete
  backups or eligible for device removal.
- Fresh phone-offload eligibility and a declared original-retention assurance
  protecting resources against concurrent application deletion/reference release.
  Define operation holds, expiry, delayed OS confirmation, and crash recovery
  before certifying device cleanup; a prior existence check alone is insufficient.
- Installation-scoped push registration, rotation, revocation, and optional
  provider/relay delivery under R30.

Specify retry/idempotency semantics and public URL reachability so clients remain
independent of internal services, database engines, and storage vendors.
Phone removal never implies server deletion; remote trash never instructs a
client to erase an independently held device original. Client behavior, cache
policy, platform restrictions, and unconfirmed UX recommendations are in
[003 - Native mobile client](003-mobile-client.md).

### 3.27 R27 - Large-library chronology and infinite-scroll API

The library service exposes an authenticated browsing API, separate from search.
It must support millions of assets spanning at least 20 years. A client can render
a chronology rail like the reference gallery: select a year, refine to a month
or date, jump directly into that period, and continue scrolling toward older or
newer media.

This requires three complementary contracts: a layered chronology index,
bounded day-level media pages, and the incremental synchronization protocol in
R29. Neither a single full-library response nor sequential pagination from the
newest asset is sufficient.

The following routes are proposed contracts:

| Endpoint | Purpose |
|---|---|
| `GET /v1/libraries` | List libraries the caller may discover/access, with effective permissions |
| `GET /v1/libraries/{library_id}/assets` | Return bounded gallery pages, including a specified day's media URIs and metadata, or continue from a date/period anchor or cursor |
| `GET /v1/libraries/{library_id}/timeline` | Resolve a published manifest and return its layered year/month/day index, counts, revisions, and seek anchors |
| `GET /v1/libraries/{library_id}/segments/{segment_id}/versions/{version}` | Read bounded media metadata from an exact retained segment version in an authorized manifest |
| `GET /v1/libraries/{library_id}/changes` | Resume authorized chronology/media changes from an opaque synchronization token |
| `GET /v1/assets/{asset_id}` | Retrieve authorized asset metadata and available representations |
| `GET /v1/assets/{asset_id}/content` | Retrieve the original or an authorized representation, supporting ranged reads where applicable |
| `GET /v1/events` | Open the authenticated R30 notification stream; media and durable deltas use separate HTTPS endpoints |

#### Chronology index and direct seeking

The timeline endpoint accepts a hierarchy `depth=year|month|day`, an optional
parent period/date range, a grouping timezone, and the same supported media
filters as browsing. Return nested, nonempty year/month/day nodes down to the
requested depth. Each node contains:

- A period key and start/end, separate `photo_count` and `video_count`, their
  total, and actual first/last asset dates.
- A node revision/ETag for validation and a child-loading/completeness state.
- An opaque seek token that opens the first gallery page for that period in the
  selected ordering, without walking earlier pages.
- For day nodes, bounded segment references for fetching that day's entries.

The response envelope carries a common browsing revision, synchronization
checkpoint, timezone, and filter/access context. Counts at a parent include its
whole authorized period, not merely the child nodes included in a partial
response. When all children are loaded at the same revision, their photo and
video counts separately sum to the parent's counts.

For example, requesting day depth for a selected year returns a hierarchy of the
following shape; media entries themselves are loaded separately:

```text
year: 2021       photos: 12000  videos: 400  revision: ...
  month: 2021-06 photos: 1000   videos: 30   revision: ...
    day: 2021-06-12 photos: 80  videos: 2    revision: ...
      media_page: /v1/libraries/{id}/assets?day=2021-06-12&...
```

#### Bounded segments and immutable manifests

Separate calendar grouping from transfer and synchronization units:

```text
Published manifest (view, generation, revision, journal checkpoint)
  -> Year/month/day nodes with photo/video counts
      -> Segment references (segment ID, version, count, sort-key range)
         -> Bounded asset metadata and representation references
```

Every asset in a view belongs to exactly one day and one segment at a given
revision. A day can contain multiple segments. Bound segments by both item count
and serialized metadata size; a malformed capture date shared by millions of
assets must not create an unbounded segment. Order by timestamp and stable asset
ID so identical timestamps are unambiguous. Counts refer to logical assets, not
physical deduplicated blobs or number of grants.

Segment IDs are independent of array positions. Updates create new immutable
versions; splits/merges explicitly retire and replace references in the next
manifest. Use local rebalancing with separate split/merge thresholds to avoid
rewriting unrelated periods or oscillating after small edits. Exact size limits
are benchmarked protocol limits, not inherited from another product.

Publish manifests and their hierarchy/segment versions as retained, immutable
metadata snapshots through the storage abstraction. Build changed nodes
copy-on-write and share unchanged versions across manifests; do not duplicate
original media. All referenced metadata objects must be durable and their counts
validated before atomically advertising a manifest as published.

The library service owns manifest reachability and retention holds; the storage
service owns the underlying metadata-object bytes. Acquire durable holds before
publication and release them only after no retained manifest needs that version.
Unpublished staging objects require crash-safe cleanup, not exposure to clients.

Historical reads resolve these actual retained versions, not current database
rows filtered by an old revision number. Repository and storage adapters must
implement this publication/retention contract without holding a database
transaction open throughout a client's browsing session.

Long-lived manifests contain stable authorized content routes and representation
IDs, not expiring bearer URLs. Resolve any short-lived delivery URLs separately
under current authorization. Segment identifiers and content hashes are never
access credentials.

The compact year overview and counts let the client label the rail and calculate
relative positions or density. The client requests month/day detail lazily for
the relevant range rather than downloading every asset or all fine-grained
buckets upfront. Clients may request multiple layers together for a bounded
range. Bound hierarchy responses with range/node limits and explicit child
continuation tokens; omitted children mean "not loaded", not an empty period.

Day media requests carry the same timezone, filters, and browsing revision as
their day node. Return bounded pages even for unusually large days. Every entry
includes its stable asset ID, asset revision, media/content URI, available
thumbnail/preview URIs, and display metadata. Stable authorized content routes
or refreshable short-lived URLs must work without exposing storage-provider
details. Expiring URLs are not asset identity.

Return dimensions and orientation before image bytes so the client can reserve
layout space. Missing dimensions require an explicit placeholder policy;
metadata or preview completion must not silently reinterpret a saved anchor.

Year/period tokens position a page within the overall chronology; they must not
implicitly restrict subsequent scrolling to that period. An explicit date-range
filter, by contrast, intentionally limits traversal.

Also support seeking directly to a supplied date/time without first fetching the
timeline. Define nearest-item behavior: in the default newest-first order, start
at the latest authorized item at or before the requested instant. Return the
resolved position, including whether the requested period was empty. Empty
libraries and out-of-range anchors return explicit empty/boundary state.

#### Bidirectional infinite scrolling

"Entire library" means all authorized items are reachable through bounded
requests. Gallery responses contain `items`, `next_cursor` toward older items,
and `previous_cursor` toward newer items in the default newest-first order.
Null cursors indicate the corresponding boundary. Keep item ordering consistent
when fetching either direction so a client can prepend or append pages.

Support bounded `limit`, an initial period/date anchor, and opaque continuation
cursors. Anchor and continuation parameters are mutually exclusive. Tokens bind
the caller, library, filters, ordering, grouping timezone, and browsing revision.

Use keyset/seek pagination with deterministic ordering, proposed as capture time
descending and asset ID as a tie-breaker. Use upload time when capture time is
unavailable. Specify capture-time normalization, timestamp precision, and
timezone rules consistently across indexing, date seeks, and bucket boundaries.
Support date-range and media-type filters without requiring a semantic query.

Do not implement a deep jump using large numeric offsets or by fetching and
discarding all intervening pages. Seeking to an old year and loading its first
page must not require work proportional to the number of preceding assets.

Example interaction:

1. Fetch the year overview and its synchronization checkpoint.
2. Expand a selected year into months/days, retaining their photo/video counts.
3. Fetch media URIs and metadata only for visible/prefetched days.
4. Page through a large day, then adjacent days, or use seek-based continuation
   across periods. Fetch newer/older pages without restarting from the beginning.
5. Apply changes using R29 and refetch only affected loaded day pages.

The native client can virtualize its rendered grid and retain only nearby pages;
the backend supplies the positioning and continuation contracts without requiring
the client to cache millions of entries.

#### Stable scroll position during changes

The client stores navigation targets as dates/periods and viewport anchors as
`{asset_id, chronological_sort_key, viewport_offset, manifest_revision}`.
Global item indices, pixels, and scrollbar percentages are derived layout state,
not durable identities.

Apply a revision transition to the client's data model atomically. Recalculate
layout, locate the same surviving anchor, and compensate the scroll offset so
that its viewport-relative position is preserved:

```text
new_scroll_offset = new_anchor_layout_position - saved_viewport_offset
```

If the anchor is deleted or no longer accessible, resolve the nearest surviving
authorized chronological neighbor, preferring the next older item and falling
back to the next newer item. If a period is empty, report that fact and the
resolved destination rather than relabeling another period as the requested one.

Pin the rail geometry/date mapping while a user drags it. Resolve the gesture to
a logical target using that pinned mapping, then apply pending layout changes at
a controlled gesture/render boundary and rebase to the same target. Version
changes must not turn a selection of 2023 into 2022 because 2024 lost photos.
Retain only bounded pending transition state during a long gesture; coalesce
updates or explicitly rebase if limits or snapshot expiry require it.

Current authorization always overrides pinned layout: on learning of revocation,
the client hides affected content, invalidates the view, and resolves an
authorized fallback without waiting for the gesture to finish. The server rejects
revoked access even before the client learns of it. Preserve visible content
where possible, not an unchanged scrollbar percentage after the total changes.

#### Consistency, authorization, and scale

Serve hierarchy nodes, seek anchors, and media segments from one retained
published manifest so concurrent mutations cannot silently skip or duplicate
items. Clients transition to later manifests through R29, rather than mixing
current-state responses into an older snapshot. The manifest's publication
checkpoint covers exactly the journal changes incorporated into that revision.

Recheck current permissions on every request; a browsing snapshot never preserves
revoked access. If a revision expires or permissions invalidate traversal, return
an explicit error and restart instruction rather than an incomplete success.

Gallery entries include identifiers, display timestamps, media type, dimensions,
video duration where relevant, thumbnail/preview availability, processing state,
and the ownership/sharing provenance from R18. Return references to media
representations instead of embedding original bytes in listing responses.
Unavailable thumbnails have explicit pending/failed states.

Library membership alone must not expose assets outside a selected-media grant.
Listings, year labels, bucket counts, seek tokens, metadata, and content routes
apply the same current authorization rules, including for shared media. Do not
expose an owner's full chronology or counts to a recipient of only a subset.
Bind a view to its authorization generation. If that generation changes, reject
incompatible retained manifests and rebuild/reissue the view; do not filter their
rows while returning the original, now-inconsistent counts. A view becoming
invalid must not block revocation while a replacement snapshot is built.

Maintain an indexed chronological read model and suitable bucket aggregates or
permission-scoped caches. Gallery navigation must not perform full-library scans
or recompute decades of grouping per request. Aggregates must handle uploads,
timestamp corrections, deletion, and sharing changes; their revision/freshness
state must be explicit rather than silently inconsistent with pages. A summary
revision/checkpoint represents only changes fully incorporated into that read
model, not unprocessed events still waiting on the broker.

Repository contracts cover seek, bidirectional traversal, and authorized bucket
retrieval; adapters implement efficient access paths without exposing database
details. Neither vector indexing nor completed face/embedding jobs is required.
No storage-object listing or original-media read is needed to generate gallery
pages. Bound response sizes and interactive resource usage independently of total
asset count.

Benchmark against a representative dataset of at least one million assets spread
over 20+ years, including skewed years, identical timestamps, missing capture
times, and selected-media shares. Define measurable latency and resource budgets
for year overview, deep date seek, and page continuation before implementation
acceptance; exact targets depend on the deployment profile. Client UI
implementation remains outside this specification.

### 3.28 R28 - Ownership and cloud-service independence

Provide a deployment profile in which identity, service databases, media storage,
broker, vector search, and ML inference all run on operator-controlled hardware.
Core backup, browsing, retrieval, sharing, face recognition, semantic search,
and cleanup classification must not require vendor accounts, subscriptions,
remote inference APIs, or proprietary cloud media catalogs.

Model/runtime downloads and installation-time dependencies must be distinguishable
from runtime service requirements. Once dependencies and model weights are
available locally, core operation must not require contacting a model provider.
External storage, cloud deployment, or tunnel providers can be selected by the
operator without becoming mandatory for other deployment profiles.

Store original bytes and authoritative library metadata under operator control.
Storage/database adapters must not make a vendor-specific catalog the only way
to locate or retrieve media. Backup/restore must retain the relationships among
originals, library entries, identities, and permissions.

#### Security-preserving backup and restore

Define a recoverable consistency set containing service persistence, identity
membership and credential metadata, storage-reference state, original and
derivative objects, retained gallery manifests/metadata, the committed
journal/outbox frontier, and processing-generation state. Backups record a
consistent checkpoint and are integrity-protected and encrypted under
operator-controlled recovery keys. A backup is not advertised as restorable
until completeness is verified.

Restore always starts quarantined: no public client access, activation/recovery,
worker consumption, manifest publication, or garbage collection. Restore service
state and media to the selected consistent point; reconcile logical assets,
storage references/holds, manifests, and journal positions before opening reads
or processing.

Advance a monotonic deployment security epoch on every restore. Maintain it in
protected recovery state outside the rollback-prone snapshot, or through an
equivalent operator-controlled ceremony. Every token, session, activation,
worker capability, job, manifest view, and delivery grant is bound to that epoch.
If the trusted epoch cannot be established, fail closed and require explicit
operator recovery; never infer that an old epoch is current.

Do not silently reactivate authority revoked after the selected backup. Retain a
separately protected, append-only security journal for account disablement,
credential/session revocation, membership, and share/grant changes, with
commit-safe ordering and integrity verification, and replay it before access is
opened. If the journal is missing, inconsistent, or unverifiable, remain
quarantined: disable accounts and shares whose current state cannot be proven,
invalidate all old sessions/capabilities, and require explicit administrator
reapproval. Restoring an old database alone is never sufficient authorization
evidence.

Only after reconciliation and security-state validation may workers restart.
Reject jobs and outputs from older epochs, rebuild derived projections as needed,
then enable garbage collection after a complete reference/retention
reconciliation. Recovery tests cover both verified journal replay and fail-closed
recovery when post-backup security changes cannot be proven.

Remote access still requires connectivity and a configured ingress; independence
from commercial media-cloud services does not eliminate those network needs.

### 3.29 R29 - Incremental client chronology synchronization

Treat the client gallery as a partial, versioned materialized view. The server is
authoritative; a client caches the hierarchy and only the media pages it needs.
Routine edits invalidate affected nodes/pages rather than requiring all media
metadata or thumbnails to be downloaded again.

#### Bootstrap without losing concurrent changes

The initial timeline response selects a retained published manifest and returns
its generation, revision, view context, expiry, and synchronization checkpoint.
Fetch hierarchy expansions and day segments through that manifest while
recording subsequent changes through the change endpoint. R30 defines how to
establish notifications without a subscribe/catch-up gap.

This handshake must cover mutations during initial loading: do not fetch a
snapshot and then independently obtain a newer checkpoint that skips changes
between those operations. Apply buffered changes after snapshot pages, or track
page revisions so older responses cannot overwrite newer synchronized state.
Switch manifest references only after completing the corresponding local
transition. Responses for retired segment versions cannot overwrite active data.

#### Durable change feed

Expose logically atomic transition batches with `batch_id`, `base_revision`,
`target_revision`, `generation`, `view_context`, and a final synchronization
token. Payloads identify changed hierarchy nodes, retired/replacement segment
versions, affected assets/periods, and removals. Large batches use bounded parts
with completeness and integrity metadata; a part-continuation token is not a
committed synchronization checkpoint. Support:

| Change | Client effect |
|---|---|
| Asset added or metadata updated | Replace affected loaded metadata/segment references and update affected hierarchy nodes |
| Asset deleted | Apply a tombstone and retire affected references together with replacement counts |
| Capture time changed | Remove old membership and add new membership, updating both day/month/year paths atomically |
| Representation ready/changed | Refresh affected loaded metadata/URIs without changing counts unless membership changed |
| Access changed | Reconcile newly visible/hidden media or explicitly reset the affected access scope |
| Cleanup suggestion or review decision changed | Reconcile the private cleanup view; ordinary gallery counts change only when assets enter or leave that gallery, such as trash/restore |

Provide authoritative replacement nodes from the target manifest. A
day/month/year becoming empty must be represented explicitly by
zero counts or a bucket-removal record; absence in an incremental page is not a
deletion signal.

Use authoritative replacement counts, not blind numeric increments/decrements.
Validate batch completeness and the expected base revision, then commit
hierarchy references, loaded-view removals/updates, target revision, and final
token as one local transaction. Swap the rendered model at a layout boundary
using R27 anchors. Missing target segment contents are explicit placeholders,
not stale old-version entries; fetch them lazily.

Unloaded segments need only reference updates. Coalesce bursts into a transition
from one committed revision to another, preserving removals and final membership
semantics. Duplicate batches are harmless; a missing base revision requires
catch-up or explicit reset, never applying patches to an unknown base.

A stable asset ID, entity revision, and batch identity prevent stale updates.
Keep delete revisions or equivalent stale-response rejection state so delayed
page responses cannot resurrect removed assets.

#### Commit ordering and publication

Record library mutations and their journal/outbox entries atomically. Establish
a commit-safe per-library ordering; assigning a sequence before a transaction
commits or taking the highest broker-delivered sequence is not sufficient.
Journal replay and projection application use a contiguous committed/applied
frontier, with explicit handling for aborted work and duplicate delivery.

An asynchronous projection publishes a manifest only after the corresponding
asset changes, counts, and immutable metadata objects are complete. Serialize
publication for each library/view; computational workers may execute in parallel,
but they cannot advance a checkpoint across missing journal changes.

Use an epoch/generation in tokens to invalidate them after incompatible restore
or rebuild. The client feed is a durable API backed by journal/manifests, not
direct broker subscriptions. A notification cannot advertise an unpublished
revision.

Catch up toward a fixed published target and report whether more transitions
remain. Changes arriving afterward belong to the next catch-up cycle. Persist
the final synchronization token only with a complete, committed batch.

#### Filter membership transitions

For date/media-type filters, evaluate both old and new membership:

| Matched before | Matches after | View change |
|---|---|---|
| No | Yes | Add |
| Yes | Yes | Update |
| Yes | No | Remove from this view, even if the underlying asset still exists |
| No | No | No asset disclosure |

Retain sufficient before/after routing information in the journal, or explicitly
invalidate the affected scope. Filtering events only by current asset fields is
incorrect: a photo moved from 2020 to 2019 must disappear from a cached 2020 view.
Treat access changes under the current-authorization rules below, not as a way
to disclose old private fields. Changed grouping/filter context requires a new
view, not reuse of incompatible tokens.

#### Deletion and access changes

Tombstones retain minimal stable identifiers and affected scope/period
information, not deleted media payloads. Deliver removals only to clients whose
authorized synchronization context previously included that item. Do not simply
filter every record by current asset readability: doing so would hide the very
removal a client must learn about after losing access.

Bound tokens to the authenticated identity, library, filters, timezone, and
access generation. A change in sharing can affect millions of assets; support
scope invalidation/rebootstrap rather than requiring one event per asset.
Purge/revalidate the affected cached view and derive access from remaining grants.
If access to the entire library is lost, return a scope-access error and require
its local view to be removed. Do not expose another user's chronology through
removal records.

The server enforces current authorization immediately, regardless of whether a
client has synchronized. A cooperative client removes revoked cached metadata
and representations, but the server cannot recall media already downloaded.

#### Offline clients, push hints, and recovery

Persist manifests, referenced metadata versions, and changes/tombstones for
defined retention periods. Advertise snapshot expiry and retain referenced
objects through that promised lifetime. Bound storage with explicit retention
and lease policy; a client cannot pin history indefinitely. Garbage collection
must account for all retained manifests, not only the latest one.

If required history is unavailable, return an explicit reset instruction and
replacement bootstrap route. A reset reacquires the hierarchy and needed media
segments while preserving an authorized asset/date anchor, not automatically
all originals or a jump to the newest photo. No partially received batch may
survive an incompatible generation reset.

Distinguish `401` authentication renewal, `403` scope-access loss, `409` view/base
revision mismatch, and `410` unavailable snapshot/delta history with machine-
readable recovery codes. Never substitute an empty success for a stale token.
Network failure keeps the last locally committed revision, clearly marked stale.

R30 supplies live hints plus reconnect/periodic catch-up. Correctness depends on
the durable HTTPS snapshot/delta APIs, not delivery of every notification.

Preserve scroll position by stable asset ID and date, not a global array index
that shifts after deletions. If the anchor disappears, resolve a neighboring
authorized asset/date. Native client storage and rendering implementation remain
out of scope; these synchronization contracts belong to the backend.

### 3.30 R30 - Real-time client/API transport contract

#### Transport selection

Use HTTPS request/response for commands, snapshots, segments, and durable delta
retrieval. Use **SSE (server-sent events)** for web/optional foreground streaming,
and optional OS push hints for native mobile clients without requiring an
application-owned persistent connection.
SSR means server-side rendering and does not define a synchronization transport.

| Option | Assessment |
|---|---|
| HTTPS + SSE | Web/optional foreground streaming: one-way hints with durable catch-up over separate requests |
| HTTPS + OS push | Native mobile hint delivery when configured and permitted; best-effort wake-up followed by durable HTTPS catch-up, with no-push operation supported |
| HTTPS + WebSocket | Valid alternative if bidirectional live messaging becomes a requirement; requires explicit framing, subscription, flow-control, and reconnect semantics |
| Custom raw TCP | Not justified for this API: browsers lack direct raw-TCP access, and public ingress/TLS/framing/authentication would require additional infrastructure |

WebSocket is not required in addition to SSE. If introduced, it carries the same
versioned event semantics and cannot replace the durable synchronization
contract. Media bytes do not travel on the notification connection. Standards-
based transport is a production architecture choice, not a temporary MVP step.

#### Notification envelope and lifecycle

`GET /v1/events` opens a bounded, multiplexed stream for requested authorized
library/view scopes. Limit scopes per stream and connections per identity/device.
Serve `text/event-stream` with UTF-8 JSON data. Each notification has a protocol
version, event ID, type, authorized scope, and type-specific payload:

```text
id: notification-opaque-id
event: library.changed
data: {"protocol_version":1,"type":"library.changed","scope":{"library_id":"lib-1","access_generation":"access-4"},"payload":{"target_revision":"rev-42"}}
```

Event IDs are notification identifiers, not durable synchronization tokens.
Clients do not infer missing mutations from gaps or compare opaque revisions
numerically. Scope identifiers in examples are illustrative, not credentials.

| Event | Meaning |
|---|---|
| `stream.ready` | Authorized subscriptions are installed; advertise heartbeat/reconnect parameters and current published targets for valid scopes |
| `library.changed` | A published revision is available; fetch durable changes from the client's committed token |
| `scope.invalidated` | Stop using the affected view and reauthorize/rebootstrap; no newly private media metadata is included |
| `stream.reconnect` | Server requests reconnect/catch-up, for example during graceful draining |

Emit heartbeat comments and define an advertised silence timeout. Notifications
may be duplicated, coalesced, delayed, or lost on disconnect. There is no
exactly-once promise. Unknown additive fields are ignored; unsupported major
protocol versions require explicit negotiation/error rather than guessed parsing.

#### Mobile push delivery

Provide an authenticated installation-scoped device-registration API for the
configured APNs/Android provider adapter. Bind registration to account, app
identity/environment, and server; rotate tokens, unregister/revoke installations,
and remove invalid provider tokens. Push tokens are sensitive routing identifiers,
not bearer credentials. Recheck current account/subscription authority before
delivery and send only minimal opaque wake-up hints, not private media metadata.

Coalesce notifications for durably published changes. Push may be lost, delayed,
reordered, or collapsed; provider acceptance is not client receipt or applied
state. It cannot authorize mutations or replace the durable journal. Ordinary
background sync must not misuse high-priority visible alerts to evade OS limits.

After device registration, clients catch up through HTTPS, including changes
committed before/during registration. Reconcile again on launch/resume and when
execution is permitted without depending on receipt of a final push. No-push
clients retain correct foreground/manual synchronization; arbitrary background
freshness is not guaranteed by iOS or Android.

The provider adapter needs credentials authorized for the distributed app.
Support appropriately configured operator builds; a stock application may need
an optional restricted relay rather than exposing its signing/sender credentials
to independent servers. Build/relay trust and deployment support must be selected
explicitly; no relay or platform push service is required for core self-hosted
backup/browsing. Provider failure does not block manifest publication or HTTPS
APIs. See client C08 for lifecycle and privacy requirements.

#### Race-free stream connect, catch-up, and reconnect

The following readiness sequence applies to SSE consumers; native push-only
clients use HTTPS catch-up after registration and on permitted execution without
waiting for `stream.ready`.

1. Authenticate and establish subscriptions; wait for `stream.ready`.
2. Bootstrap if there is no valid local revision, otherwise request deltas from
   the last locally committed synchronization token.
3. While catching up, coalesce hints and repeat catch-up if another revision may
   be available. Every advertised target must already be durably published.
4. On disconnect, retain committed local state; reconnect with jittered
   exponential backoff and catch up again after readiness.
5. On foreground/resume and at a bounded reconciliation interval, check durable
   state even without a hint. If streaming is unavailable, use bounded polling.

Bound connection establishment and readiness waits. A missing notification
service must not delay gallery bootstrap indefinitely: fall back to HTTPS
bootstrap/catch-up and polling after the configured timeout.

Install subscriptions before announcing readiness, then read the durable
published frontier so a commit around connection setup cannot fall into an
unobserved subscribe/catch-up gap. Gateways may reconnect to internal fan-out;
missed internal notifications must trigger catch-up hints or be covered by
periodic reconciliation.

SSE `Last-Event-ID` may assist hint replay if supported, but never substitutes for
the application's committed delta token. Mobile background execution is not
assumed: a suspended client catches up on resume. Polling fallback must provide
the same data correctness, with potentially higher latency.

#### Authentication, authorization, and connection limits

Native clients or browser fetch-based SSE use authorization headers. Browser
native `EventSource` cannot set arbitrary authorization headers; use an approved
same-origin secure cookie/session design or fetch-based streaming. Never place
long-lived access tokens in event URLs. Apply explicit origin/CORS policy and
CSRF protection to cookie-authenticated mutation endpoints.

Authorize every subscription and enforce session expiry/revocation on active
streams, not only at connection opening. Close or invalidate subscriptions when
access is lost. All follow-up HTTPS requests independently enforce current
authorization. A notification or retained connection is not an access grant.

Configure finite per-client output buffers. Coalesce repeated change hints by
scope; for a slow consumer, close the stream and require durable catch-up rather
than growing memory without bound. Control notifications have priority over
ordinary hints. Advertise/configure maximum event size, connection/scope limits,
heartbeat/silence intervals, and polling/backoff limits.

Deployment gateways must flush events, avoid incompatible response buffering,
and have idle timeouts compatible with heartbeats. Require heartbeat/reconnect
behavior to work through the supported Compose, Swarm, and Kubernetes ingress
profiles. Snapshot publication and request APIs remain available independently
of the notification gateway.

#### Observable production behavior

Track publish-to-notification and publish-to-client-apply lag, active streams,
reconnect rate, dropped/coalesced hints, slow-consumer disconnects, snapshot/delta
reset frequency, and snapshot/history storage growth. Define production latency,
retention, and resource targets for documented deployment profiles. Measure
degraded polling behavior separately from connected-stream behavior.
For push, separately measure dispatch/adapter failures, invalid registrations,
and observed client catch-up; do not equate provider acceptance with delivery.

### 3.31 R31 - End-to-end testability and test-driven development

Testability is an architectural invariant, not a later QA phase. Every supported
user journey, asynchronous state transition, failure/recovery path, and adapter
integration must have an automated E2E verification path. If a service boundary
or dependency prevents such a test, change the architecture or integration rather
than exempting that behavior.

#### Production-equivalent, isolated environments

Provision a complete disposable stack with the same application images,
authentication server, broker, repositories, storage adapters, search engine, and
processing components used in production. Configure it through documented
deployment inputs; do not introduce a separate test-only business implementation.
Isolate users, namespaces/databases, queues, volumes, and credentials for each
run. Setup and teardown must be reproducible without manual administrator edits
or touching production data.

Use public user APIs and the private admin portal/API for provisioning and
assertions. Test the private boundary from both allowed and denied network
positions. Inspect diagnostic state for troubleshooting, but do not prove a
user-visible result solely by querying an internal database.

An API-driven client simulator covers multi-client and offline synchronization.
Browser E2E exercises the admin console and, when an end-user UI is implemented,
rendered chronology anchoring and rail gestures. Future native client tests
extend the same contracts. Browser virtual WebAuthn authenticators exercise real
identity-provider passkey flows; they do not claim to test Apple's biometric
hardware. Device-specific enrollment/login gets separate supported-device
acceptance evidence.

#### Observable asynchronous completion and controlled failures

Expose authorized operation/job status resources, revisions, and correlation IDs
so tests can await a specific causal outcome with a deadline. A quiet queue is
not proof of success, and fixed sleeps are not synchronization. Surface failed,
cancelled, stale, and dead-letter outcomes explicitly.

Support deterministic fixture import through normal APIs, seeded media with
expected dates/hashes, controllable time at the infrastructure/clock boundary,
and network/process fault injection. Inject failures through the test harness
or deployment controls, not public production bypass endpoints. Verify token
expiry, retention, recovery, duplicate/out-of-order delivery, worker restart, and
notification loss without waiting for real-world retention periods.

Use at least two independent client states to prove synchronization under
concurrent uploads, moves, deletions, access changes, and stale responses. A
successful mutation response alone is not proof that another client converged.
Preserve an artifact bundle on failure: redacted logs, traces, batch/revision
identifiers, and browser evidence where applicable.

#### Real dependencies and layered feedback

Unit, property/state-machine, and adapter contract tests complement E2E tests;
they do not replace them. Prefer red/green/refactor for protocol invariants,
repository semantics, state machines, and regressions where the expected
behavior can be specified before implementation.

Small deterministic inference fixtures or doubles can shorten fault/contract
tests, but a passing double-only suite is not full-system evidence. Run bounded
real-model E2E scenarios for detection, manual identity correction, embedding,
retrieval, and cleanup classification. Version datasets/models and evaluate
recall/quality tolerances instead of asserting bit-identical floating-point
embeddings.

Keep shared contract tests for every supported database/storage/vector adapter
and E2E evidence for each declared deployment profile. Define risk-based matrix
coverage for supported combinations explicitly; do not imply every arbitrary
engine/provider combination is certified. Run quick E2E journeys on changes and
scheduled/release suites for real inference, restore, failure injection,
production-scale datasets, and orchestrator/network boundaries. Scheduling a
suite less frequently does not remove its acceptance requirement.

Map R01-R33 and the acceptance scenarios below to test identifiers, fixtures,
supported profiles, and observable outcomes. New functionality is not complete
without this traceability and executable evidence. Since this repository
currently contains specifications only, these are required future test
capabilities, not a claim that an E2E suite already exists.

### 3.32 R32 - Cross-cutting security contracts

Security controls apply across supported deployment profiles and are mandatory
architecture contracts, not optional hardening:

- **Identity:** R08/R09 define closed provisioning, passkey-only login,
  account-bound single-use activation, recovery proof, global credential/session
  revocation, and fail-closed disabled-account state.
- **Untrusted inputs:** R21/R24.1 define parser/inference isolation,
  input/output scoping, default-deny egress, resource ceilings, safe model
  loading, artifact integrity/provenance, and controlled updates.
- **Internal workloads:** R24 defines authenticated workload identities,
  broker ACLs, job-scoped capabilities, attempt/revision fencing, and owning-
  service validation. Network locality or message possession is not authority.
- **Annotations:** R19 defines user-private person labels/corrections by default,
  with separate explicit view/edit grants; deduplicated bytes never transfer
  annotation ownership.
- **Recovery:** R28 defines consistency sets, quarantine, monotonic security
  epochs, protected revocation history, fail-closed recovery, and
  post-restore reconciliation before GC or clients resume.

Security evidence is captured through R31 E2E scenarios 24-29, in addition to
unit, property, adapter-contract, and deployment-boundary tests. Threat-specific
abuse tests are release gates for the relevant feature. A passing specification
or test plan is not implementation evidence; every supported profile must
demonstrate the control before it is certified.

### 3.33 R33 - AI-assisted media cleanup

Treat "unwanted" as a user's judgment, not an objective property of a file.
Produce review candidates, never automatic deletion, hiding, or upload rejection.
A blurry family photo may be irreplaceable; a screenshot may be a receipt or
important record. A classifier detects signals, not whether an asset has value.

#### Classification and processing

Use a dedicated curation service with its own repository adapters and bounded
worker queue, reusing the ML inference boundary in R24/R25. Run incrementally on
new/changed assets and support resumable whole-library scans and model upgrades.
Library browsing and upload acceptance remain independent of this pipeline.
Expose scan progress, coverage, failed/unsupported assets, and retry status;
missing or failed analysis must not appear as a successful "nothing to clean."

Combine inexpensive quality/metadata signals with a locally hosted, multi-label
content classifier. Candidate categories include:

- Likely memes, reaction images, social-media forwards, and promotional images.
- Out-of-focus or motion-blurred captures and other severe quality defects.
- Screenshots and screen recordings that the user may no longer need.

Use source-app/import provenance only when supplied, preserving its trust level;
appearance alone cannot prove where media came from. Age and screenshot
detection can help rank suggestions, but cannot establish that a record has
expired. Distinguish intentional depth-of-field or motion effects from unusable
captures. For video, use bounded temporal sampling and quality aggregation;
record sampled intervals and incomplete coverage rather than judging an entire
clip from one poor frame.

Return reason codes, category scores with documented meaning/calibration, and
supporting quality measurements or video timestamps. Abstain on uncertain or
unsupported inputs; a score is not the probability that a user should delete.
Semantic embeddings may be reusable features, but text similarity alone is not
a validated cleanup classifier. Model, thresholds, and sampling policy remain
open until evaluated on representative data; no provider or model is hardwired
into the API.

#### Private decisions and review API

Separate versioned machine assessments from user decisions. Curation owns the
assessments; record asset/source revision, model/preprocessing generation, and
assessment time. The library service owns category preferences, sensitivity,
exclusions, and keep/dismiss history alongside asset permissions and protections.
These are private to that user's library view, never properties of the canonical
blob. Shared media does not expose another user's opinions or train their
preferences. Feedback may tune that user's ranking/thresholds; global training
or cross-user learning requires a separately designed opt-in contract.

The library API composes curation results with current asset authorization.
Provide cursor-paginated cleanup candidates and category summaries, filtered by
library, media type, category, score, date, and review state. Include stable
candidate/asset IDs, asset and candidate revisions, reasons, authorized preview
URIs, logical byte size, and allowed actions. Bind pagination to a retained
candidate-view revision and filter context; use R27/R29 snapshot, expiry, and
reset semantics rather than unstable offsets. Counts cover authorized candidates
only; distinguish scanned coverage from the entire library.

Provide idempotent keep, dismiss, preference-update, and confirmed-trash
operations. Keep protects an asset from future cleanup suggestions until the
user explicitly removes that protection; dismiss suppresses the reviewed
assessment. Reprocessing the same asset must not undo either decision. A model
upgrade may resurface a dismissed candidate only through an explicit user
rescan/reset of dismissals. Allow library/album and category exclusions; apply
keep/exclusion protections before presenting or executing a cleanup action.

Record private review-resume/defer state for mobile "Later" actions separately
from keep/dismiss and machine training feedback. Deferral must not immediately
reinsert the same candidate into an active batch or loop across devices; the
revisit policy is an explicit client/server contract, still open for UX review.
Silence and dialog cancellation do not constitute feedback or deletion consent.

Validated assessment events feed library-owned, user-scoped candidate projections
through durable publication, not cross-service database writes. Review decisions
and their journal entries commit within the library service. Publish private
review changes and candidate additions/removals through R29 catch-up and R30 hints,
including large-rescan scoped resets. A suggestion alone never removes an asset
from the normal gallery. Late worker results cannot overwrite decisions or
resurrect deleted assets; fence on source, model, and decision revisions.

#### Confirmed removal and recovery

Only an explicitly confirmed user command to the library service may move
selected assets to trash. The classifier has no deletion or reference-release
authority. Confirmation identifies a bounded set of assets and expected
asset/candidate/decision revisions, never a live "delete everything matching"
query that can expand while classification changes. The library service checks
current delete permission, protection state, and projected candidate revision
atomically with each trash mutation; a preceding remote check alone is
insufficient. Return explicit per-item outcomes and conflicts. A shared viewer
cannot delete the owner's asset by accepting a suggestion.

Trash removes media from ordinary gallery/search/shared views with normal R29
removals, but retains bytes and metadata for a deployment-configured recovery
period whose deadline is returned before confirmation. Authorized restore
within that period preserves the asset identity and user decisions; it does not
reactivate subsequently revoked grants. Final deletion follows R16 reference
and retention rules, never a direct classifier call to storage.

Show selected logical bytes separately from physical space reclamation. Trash
does not immediately free storage; other assets, backups, and retention holds
may keep the same bytes. Do not expose private deduplication/reference information
through savings estimates or promise physical savings that cannot be guaranteed.

#### Quality and acceptance

Evaluate each category with versioned, consented or synthetic fixtures covering
valuable blurry photos, intentional blur, useful screenshots/documents, memes,
ordinary family photos, and mixed-quality videos. Report per-category precision,
recall, false-positive rate, and abstention/coverage, separately from a user's
subjective keep/delete decision. Establish numerical acceptance thresholds and
resource budgets before certifying a model, prioritizing low false positives.
No model score bypasses review. Prefer TDD for review, authorization, revision,
trash, and synchronization invariants; real-model E2E evidence is also required.

### 3.34 Open decisions and acceptance evidence

Before implementation, resolve or explicitly defer:

- Generic file/drive extension in R02 is deferred follow-up work. Its upload
  entry-point topology and file/photo ownership relationship remain open;
  shared ingestion is a recommendation, not a selected API change.
- Resource budgets and expected library size; physical disk layout is an
  operator concern, not a prerequisite for application design.
- Initial language/framework choices and supported persistence adapters.
- Identity provider selection and account activation delivery integration. The
  passkey-only, recovery-code/admin recovery, revocation, and disabled-account
  policies in R08/R09 are fixed contracts, not open choices.
- Protected security-journal and monotonic-epoch implementation, recovery-key
  custody, and backup consistency-set mechanics must be selected while
  preserving mandatory fail-closed restore behavior in R28.
- Broker, vector engine, initial storage-adapter implementation order, and public
  ingress.
- Deduplication/trust scope and encryption requirements.
- Optional annotation-sharing configuration; the default isolation and explicit
  grant requirements in R19 are fixed.
- Sharing defaults, including future assets, editing, and resharing.
- Resource budgets and reindex availability policy.
- Chronology API limits and latency/resource targets for million-asset datasets,
  including browsing-revision lifetime and aggregate freshness guarantees.
- Snapshot/delta retention budgets, bounded segment sizing, lease policy, and
  notification connection/heartbeat/reconciliation limits.
- Mobile build/signing and push provider/optional relay trust, original-resource
  support matrix, and phone-offload retention/eligibility mechanics; client
  recommendations and open UX decisions are recorded separately in spec 003.
- E2E harness/tooling, fixture corpus, supported profile matrix, and CI resource
  budgets; testability itself is not optional.
- Cleanup classifier, category thresholds/calibration, video sampling, quality
  acceptance budgets, and trash recovery period; explicit review, privacy, and
  no automatic deletion are fixed R33 contracts.

Production acceptance scenarios must demonstrate:

1. An admin provisions a user privately; public registration is impossible.
2. A known user logs in using a passkey.
3. An interrupted upload resumes with out-of-order parts and verifies correctly.
4. Identical uploads converge on one canonical blob within the chosen scope,
   without leaking private content or granting unauthorized access.
5. Sharing exposes provenance; revocation and deletion preserve independent
   access and remaining blob references.
6. Queued face and semantic processing respect resource limits.
7. A manual identity merge survives reprocessing and can be corrected.
8. Combined person/text search returns only authorized media.
9. A model migration rebuilds the library without mixing generations.
10. Administration works from the configured authorized private network and is
    unreachable through every public entry point, in both home and cloud
    deployment profiles.
11. Storage contract scenarios cover mounted-volume, S3, and Azure adapters,
    including resumable uploads, ranged reads, deduplication, and safe deletion,
    without changing client or domain contracts.
12. With at least one million assets spanning 20+ years, a client can render an
    authorized year rail, jump directly to an old year/month/date, and scroll in
    both directions across year boundaries without large-offset queries or
    downloading intervening assets. Browsing and original retrieval work while
    search/ML services are unavailable. Equal timestamps, empty periods,
    concurrent changes, and cursor expiry follow the documented rules, and
    revoked/unshared assets or chronology counts are never exposed. Requests
    satisfy the agreed latency/resource budgets.
13. The self-hosted profile performs core operations with all dependencies and
    model weights hosted locally and no mandatory proprietary cloud account or
    external inference service.
14. Layered year/month/day responses report separate authorized photo/video
    counts that reconcile at a common revision, while clients load media URIs
    and metadata only for needed days, including pagination within a large day.
15. With two clients open, one client's deletion removes the asset from the
    other's cache and refreshes affected day/month/year counts without a full
    reindex. Verify timestamp moves, empty-bucket removal, repeated/out-of-order
    responses, concurrent bootstrap changes, and stable scroll anchoring.
16. A client reconnecting within retention catches up from its token; an expired
    token or large sharing change triggers an explicit scoped reset. Revocation
    is enforced before synchronization, and change records disclose no
    unauthorized media.
17. While viewing 2026, deletion of 100 photos in 2024 neither shifts the visible
    anchor nor redirects a year-2023 gesture into 2022. Exercise deletion above
    the viewport, anchor deletion, rail dragging, grid resize, and late previews.
18. A client finishes reading a retained snapshot while newer revisions move
    assets across days and split/merge segments. Counts and membership match the
    selected revision; expired versions return explicit recovery responses.
    Millions of identical timestamps still produce bounded segment payloads.
19. A filtered 2020 view receives a removal when a photo moves to 2019. Multi-
    part changes commit atomically; retry, crash, and delayed responses cannot
    double-update counts, lose a move, or resurrect retired entries.
20. Reordered/duplicate journal deliveries cannot advance the applied frontier
    past missing work. A crash between metadata-object creation and manifest
    publication yields no partially published snapshot.
21. Disconnect or restart the notification gateway during a commit, drop hints,
    expire credentials, revoke access, and simulate slow consumers. Connected,
    reconnecting, and polling clients converge through durable catch-up without
    unbounded buffers, unauthorized events, or silent revision gaps.
22. Provision and destroy an isolated production-equivalent environment
    automatically; exercise provisioned-user passkey login, upload, asynchronous
    processing, sharing, two-client synchronization, and deletion through
    supported APIs without manual setup or fixed sleeps.
23. E2E fault scenarios observe causal operation/revision completion, detect
    failed/dead-letter work, and prove restart/retry convergence with redacted
    diagnostic artifacts. Selected real-model and supported adapter/deployment
    profiles run under the documented acceptance matrix.
24. Enrollment and recovery tests prove activation binding, single use, expiry,
    password login is rejected, recovery-code replay rejection, verified
    administrator recovery, global credential/session revocation, audited
    operation, and no implicit account re-enablement.
25. Processing tests run hostile media and instrumented parser workers with
    attempted host/provider/other-asset access, malicious metadata fetch targets,
    oversized decoded output, and unverified model artifacts; isolation denies
    access and bounded jobs terminate without publishing invalid results.
26. Broker/workload tests reject unauthorized producers, consumers, topics,
    audiences, jobs, attempts, inputs, outputs, and permanent-reference releases.
    Deleted/cancelled/superseded jobs cannot write stale results.
27. Restore tests use a backup predating user disablement, credential revocation,
    and share removal. The system remains quarantined until security reconciliation;
    old sessions, activation links, delivery capabilities, and jobs cannot regain
    authority.
28. Artifact tests alter image/model bytes and provenance, attempt executable
    custom loading, and verify fail-closed behavior, controlled rollback, and
    offline use of verified artifacts.
29. Two users upload identical bytes and create distinct person labels, aliases,
    merges, and corrections. Nothing crosses scopes unless the explicit
    annotation-view grant exists; revocation removes that view without changing
    the other user's annotations.
30. Upload representative photos/videos and scan an existing library through
    normal APIs. Real-model cleanup candidates expose reasons, calibrated
    category scores, coverage, and measured category-quality results; valuable
    blurry photos and useful screenshots are included in false-positive
    evaluation. Classifier failure is visible and does not block browsing or
    uploading, hide media, or delete anything.
31. Keep/dismiss decisions and exclusions survive retries, two-client edits,
    restart, rescan, and model upgrades without leaking between users sharing
    identical bytes. Paginated candidate views and offline catch-up converge
    after review, permission changes, and large rescans; stale output cannot
    overwrite a newer decision or resurrect a deleted asset.
32. Confirm a bounded cleanup selection, concurrently change permissions or
    protect an asset, and verify explicit per-item conflicts without unauthorized
    trashing. Retry safely, restore before the advertised deadline, and race
    restore against expiry/GC. Preserve revoked grants, remaining blob references,
    and gallery anchoring; distinguish logical bytes from delayed or unavailable
    physical reclamation.

### 3.35 Design reference

[Yandex Disk's engineering description of gallery clustering and Smartcache
synchronization](https://habr.com/ru/companies/yandex/articles/849584/) describes
bounded chronological clusters, retained snapshots, deltas, coalescing, and push
hints. It informs this design but does not prescribe our segment limits or
service topology. The scroll-anchor and gesture-reconciliation contracts here
are this platform's requirements, not claims about undocumented Yandex UI logic.
