# Native Mobile Media Client Specification

## 1. Project definition

### 1.1 Purpose

Provide iOS and Android clients for the self-hosted
[media platform](000-media-platform.md). Back up device photos/videos, browse
the remote family library, share with known users, and reclaim phone storage
without retaining another full copy of the library inside the application.

There are two independent cleanup journeys:

- **Free up phone space:** remove a verified backed-up device copy without
  deleting its server asset.
- **Review library cleanup:** review AI suggestions and explicitly move unwanted
  server assets to recoverable trash under backend R33.

Neither action implies the other. This is a production north-star specification,
not an MVP or a promise of unrestricted mobile background execution.

### 1.2 Scope and decision status

Native integration is required for the OS photo library, permissions,
background transfers, secure credentials, push delivery, and local removal.
The MVP selects Swift with SwiftUI/UIKit for iOS; Android implementation and
future code-sharing decisions remain open.
The existing backend remains responsible for identity, durable uploads, media
authorization, classification, and synchronization.

Established from the requested scope: configurable backend URL, optional local
discovery, authentication, gallery, sharing with known users, push-based update
hints, phone-space reclamation, and small batches of AI cleanup candidates.
Interpret "permanently cached ... defeat the purpose" as **not permanently
cached**; temporary bounded previews and upload staging are still necessary.

The MVP discussion confirms two independent opt-in settings: automatic backup
of all accessible existing/new photos and videos, and automatic removal of
verified backed-up device media. Both obey OS execution/permission/confirmation
requirements; this does not promise unattended deletion where iOS disallows it.
The 24-item AI cleanup batch remains a recommendation, not a selected value.
Other settings and Android implementation remain to be designed.

Supporting specifications:

- [000 - Backend requirements and contracts](000-media-platform.md).
- [001 - System architecture](001-system-architecture.md).
- [002 - Threat model](002-threat-model.md).
- [004 - MVP stack decisions and draft execution plan](004-mvp-execution-plan.md).

## 2. Requirements

| ID | Requirement |
|---|---|
| C01 | Support native OS integrations, with Swift/SwiftUI/UIKit selected for the iOS MVP and Android implementation/code sharing left open. |
| C02 | Allow manual backend URL setup and permission-aware local server discovery, with explicit server trust and safe endpoint changes. |
| C03 | Authenticate only administrator-provisioned users using the backend's passkey/passwordless identity contract. |
| C04 | Access device photos/videos through supported OS APIs, honoring denied, limited, changed, and revoked permissions. |
| C05 | Preserve complete supported original media resources and establish verifiable backup completion before allowing local removal. |
| C06 | Persist resumable upload state and recover from interruption, duplicate callbacks, process death, and network changes. |
| C07 | Use OS-supported scheduling and transfer facilities with bounded battery, network, storage, and background-work consumption. |
| C08 | Receive optional OS push hints and synchronize reliably over HTTPS without requiring a persistent application connection. |
| C09 | Browse million-asset remote chronologies through layered counts, lazy pages, direct date jumps, and stable scroll anchors. |
| C10 | Display photos/videos on demand and expose backend semantic/person search without making browsing dependent on AI availability. |
| C11 | Share selected media or permitted libraries with backend-authorized known users and show shared-media provenance. |
| C12 | Offer opt-in automatic removal of eligible, verified backed-up device media, respecting OS execution/consent requirements and synchronized-library consequences. |
| C13 | Keep local removal, server trash, cache eviction, and reimport decisions separate and recoverable where supported. |
| C14 | Bound persistent preview, original, staging, and metadata storage; do not permanently cache uploaded originals by default. |
| C15 | Preserve committed offline state, clearly surface stale/pending/error states, and reconcile safely across clients and backend generations. |
| C16 | Provide a dedicated AI cleanup review experience with only a few dozen candidates in an active batch. |
| C17 | Distinguish keep, dismiss, later, and confirmed trash actions; preserve user decisions through rescans and model changes. |
| C18 | Provide understandable status and the operational settings needed for connections, backup scope, resource policies, and storage. |
| C19 | Protect credentials, private media, device registrations, and account/server boundaries across all native and UI components. |
| C20 | Provide accessible, responsive media browsing and review without relying on destructive gestures or inaccessible status indicators. |
| C21 | Make supported client journeys end-to-end testable with the real backend and appropriate OS/device evidence; prefer TDD for deterministic invariants. |

## 3. Solutions by requirement

### 3.1 C01 - Native boundaries and presentation

Separate presentation, a durable client synchronization/transfer coordinator,
local persistence, and platform adapters. Platform adapters cover PhotoKit on
iOS, MediaStore/photo-picker integration on Android, secure key storage, system
authentication sessions, OS transfer scheduling, and push registration.

Gallery virtualization, selection, navigation, and settings need not depend on
native photo-library objects. Local media identifiers and remote asset IDs are
different types; a local filename is neither an identity nor backup evidence.

Swift with SwiftUI/UIKit implements these boundaries for the iOS MVP. A UI
layer must not own the only copy of pending upload state or need to remain
active for OS-managed transfers. Section 4 retains alternatives for future
platform decisions; it does not reopen the selected iOS implementation.

### 3.2 C02 - Connection setup and local discovery

Accept a canonical HTTPS backend URL, including a supported deployment base
path. Probe a bounded, versioned capability response before login: server
identity, API compatibility, configured authentication issuer, and supported
features. Do not silently guess a different account/server from a failed URL.

Optionally discover local deployments through DNS-SD/mDNS using Bonjour and
Android NSD, with a deployment-configured service type. The server advertises
only minimal connection/version information, never users, credentials, library
metadata, or private administration routes. The advertisement component is
optional and attached to the reachable LAN edge, not assumed to work across
subnets, VPNs, cloud ingress, or container networks.

Request local-network permissions when discovery is used; retain manual setup
when discovery is denied or unavailable. Stop discovery outside the bounded
setup/connection workflow rather than continuously scanning in the background.

An advertisement is an untrusted suggestion. Show the discovered server for
selection and verify HTTPS and the configured identity before authentication.
An operator-provided QR/pairing record can convey independently trusted server
identity information; discovery alone cannot establish trust.

Remember the approved server and issuer. Address changes must preserve that
verified identity or require a fresh setup flow. Never follow advertisements,
redirects, or alternate LAN URLs with existing credentials to an unapproved
origin. Prefer one canonical hostname with suitable DNS; alternate origins need
explicit validation. Production does not disable TLS verification. Private CAs
need an explicit supported trust-installation/rotation path.

### 3.3 C03 - Authentication

Use OIDC Authorization Code with PKCE through the OS authentication session,
not an embedded credential form. Honor the configured issuer, redirect binding,
state, and nonce validation. There is no public registration or password fallback.
Face ID/Touch ID and Android biometrics unlock credentials locally; biometric
templates are not sent to the backend.

Passkeys retain the backend's stable relying-party domain even when network
routes change. Adding credentials or recovering an account uses backend R08/R09,
not a client-specific bypass. An optional local app lock is separate from
server authentication and cannot turn an expired session into valid authority.

Refresh through a serialized secure session coordinator. On expiry, disablement,
or revoked access, stop unauthorized work and request authentication where
appropriate; never reinterpret an authorization error as an empty library.

### 3.4 C04 - Device-library access

Support explicit selected-item import and a user-approved ongoing backup scope.
Explain the difference between limited photo access and access sufficient for
automatic discovery of new media. Cloud-library browsing remains available
without granting device-library access.

Use OS change notifications as hints and rescan/reconcile the permitted scope
when execution is available. Limited permissions cannot prove that excluded
assets are backed up, absent, or deleted. Persist a scope checkpoint and handle
permission expansion/reduction, library resets, and stale local identifiers.

Read resources through OS APIs, not unrestricted filesystem enumeration.
Handle originals stored only in another photo-cloud service as a visible
network-dependent export step; do not substitute a thumbnail or transcode and
claim the original was backed up. Unavailable or permission-denied resources
remain ineligible for phone cleanup.

### 3.5 C05 - Backup evidence and compound assets

Define a versioned lossless backup contract for each supported media type.
Preserve original bytes and the required resource set: for example, Live Photo
image/video pairs, supported RAW/JPEG pairs, and original plus supported edited
renditions/adjustment metadata. Embedded metadata remains part of the unchanged
original; optional indexing/sharing of capture/location metadata follows privacy
settings and must not silently replace a lossless backup with a stripped copy.

Do not promise full reconstruction of OS-specific editing/library state unless
it is actually supported and tested. If required resources cannot be preserved
and restored, show that limitation and block phone-space cleanup for that item.
Partial uploads of compound assets are not complete backups.

Persist a mapping of installation/account/server, local asset identity and
source revision, required resource manifest, verified hashes/sizes, and remote
logical asset/resource revisions. Hash the exported bytes, not a preview; hash
or export large files in bounded work rather than blocking the UI.

Backup completion requires authoritative verification of all required bytes,
durable storage references, and a committed asset owned by the uploading user.
HTTP success for a chunk, provider ETags, queued finalization, shared read access,
or completed thumbnail generation are not sufficient evidence. Client deletion
eligibility also requires the fresh safety check in C12.

### 3.6 C06 - Durable, resumable uploads

Use backend intents, safe deduplication, arbitrary-order chunk upload, and
asynchronous finalization/status contracts. Persist intent/idempotency keys,
resource manifests, chunk acknowledgements, source revisions, and operation IDs.
Reconcile authoritative uploaded-part state after interruption; do not assume
that a timed-out request failed or a callback can arrive only once.

Represent exporting, queued, uploading, verifying, durably backed up, paused,
failed, and source-changed states distinctly. A changed local source invalidates
backup evidence for that revision. Restarting or reinstalling the client cannot
make a filename-only match eligible for deletion.

Keep bounded file-backed staging where required by OS background transfers.
Do not remove an in-flight request body to meet a cache budget; defer new exports
and report low space instead. Reconcile surviving OS tasks with the durable
ledger on launch and preserve retry-safe source mappings.

### 3.7 C07 - Scheduling and resource policy

Use iOS background URLSession transfers and permitted background task scheduling;
use Android WorkManager or task-specific user-initiated transfer facilities as
appropriate to the supported OS versions. Foreground services, if needed, obey
their type, visibility, permission, and execution restrictions.

The OS controls execution. Silent push is not a persistent background worker,
and suspension, force quit/stop, battery restrictions, reboot, and unavailable
network can delay discovery and transfers. Surface pending/deferred work rather
than promising immediate backup while the app is not running.

Configure bounded concurrency, staging, retry/backoff, and per-run work.
Expose Wi-Fi/cellular, roaming, charging, and battery policies; exact settings
and defaults remain open. Manual foreground upload can make progress when
background opportunities are scarce. Complete OS callbacks within their budgets
and checkpoint unfinished work for later.

### 3.8 C08 - Push hints and durable synchronization

Use HTTPS for commands, media, snapshots, and backend R29 delta catch-up.
The mobile client does not require an application-owned SSE/WebSocket/raw-TCP
connection in either foreground or background. Foreground SSE may be an optional
optimization; web clients can retain the backend's existing SSE contract.

APNs and, where configured, Android FCM deliver coalescible wake-up hints.
On permitted execution, authenticate and fetch changes from the last committed
token. Hints can be lost, duplicated, reordered, delayed, or collapsed. They
never carry authoritative mutations, authorize deletion, or advance a sync token.
Catch up on launch/resume, network recovery, explicit refresh, and bounded
foreground reconciliation even without a push.

Register push tokens through an authenticated, installation-scoped device API.
Bind provider, app identity/environment, account, and server; handle token
rotation, invalid tokens, logout/unregister, and registration revocation.
Treat tokens as sensitive routing identifiers, not authentication credentials.

Use generic opaque routing hints, not photos, people names, filenames, tokens,
download URLs, or private chronology counts in provider-visible payloads.
The backend uses current authorization for any subsequent data response.
Ordinary sync uses appropriate background/normal delivery priority, not
high-priority user-visible alerts as a way to evade scheduling limits.

Push requires provider infrastructure and application signing/sender credentials.
A stock distributed app cannot safely hand its APNs/FCM sending credentials to
every independently deployed backend. Support direct operator-configured delivery
for compatible operator-controlled builds; an optional restricted relay for a
distributed build requires a separate trust/deployment contract. No relay is
implicitly mandatory, and no provider secret is distributed inside the client.
Exact build/distribution/relay support remains open.

Core backup and browsing work without push, Google Play services, or a product
relay while the app is executing. Background freshness is best effort; scheduled
catch-up depends on available OS facilities, not a continuously running poller.
Notification permission/provider failure does not disable synchronization.

### 3.9 C09 - Remote chronology

Implement backend R27/R29 manifests: year/month/day counts, bounded day segments,
direct date seek, bidirectional cursors, and lazy metadata/preview loading.
Do not download an entire million-asset catalog to render the timeline.

Virtualize views and bound in-memory pages. Preserve
`{asset_id, chronological_sort_key, viewport_offset, manifest_revision}` anchors.
Pin year-rail mapping during gestures; removing media from an earlier year must
not reinterpret a selected date or move the current viewport to another year.
Deleted anchors resolve to an authorized neighbor/date.

Stage and atomically commit complete delta transitions with their sync tokens.
Honor history expiry and scoped resets, and reject late retired-page responses.
Photo/video counts reconcile to one revision; equal timestamps and huge days
do not create unbounded payloads.

### 3.10 C10 - Viewing and search

Load appropriate thumbnails/previews for the current viewport and request higher
resolution on demand. Stream video with supported ranged/segmented retrieval;
bound read-ahead and cancel work for views no longer needed. Do not fetch a large
original solely to render its gallery tile.

Expose free-text and authorized person filters through backend search APIs,
including name ambiguity and explicit unavailable/indexing states. Gallery
browsing and backed-up originals remain usable when AI/search is unavailable.
Client-side AI retraining and an independent cleanup classifier are not required.

Downloading/exporting an original into the OS photo library is a distinct,
explicit action, not a side effect of opening it. Distinguish remote-only media
from available previews and complete local originals.

### 3.11 C11 - Sharing and known recipients

Provide a backend-authorized, paginated/searchable recipient directory for the
configured sharing domain. Administrators control which provisioned users are
eligible/discoverable; return stable user IDs and minimal display information.
The client never queries identity-provider administration or lists all accounts
simply because it is authenticated.

Select permitted recipients and preview the scope: explicit assets or a library,
effective rights, and whether future media are included. Confirm through an
idempotent backend command and revalidate eligibility/permissions at commit.
Handle a disabled recipient, revoked sharer authority, duplicate names, and stale
directory entries explicitly. Read-only sharing remains subject to backend policy.

Highlight shared-in media and its provenance; multiple valid access paths may
exist. Revoking one grant does not necessarily remove all access. Viewing media
does not imply delete/reshare rights or visibility of another user's private face
annotations and cleanup decisions.

### 3.12 C12 - Free up phone space safely

Provide separate opt-in settings for automatic backup and automatic phone-copy
removal. Enabling removal authorizes the application to initiate cleanup of
eligible verified backups, subject to platform execution and consent rules; it
does not bypass an OS confirmation or authorize server deletion. While disabled,
no automatic removal is initiated. Explain eligibility and synchronized-library
consequences at opt-in, and show items pending required confirmation or blocked
by permissions. A user-triggered cleanup screen remains available for review.

Before invoking the OS removal API, obtain fresh authenticated server evidence
that every required resource/revision is durably retained in the user's own
non-trashed asset, and revalidate the current local source revision and complete
resource mapping. Offline cached receipts alone are insufficient. Unverified,
partially exported, changed, inaccessible, or independently shared-in media are
not eligible. Show per-item conflicts/failures and preserve their local copies.

Backend eligibility must include a declared recovery/retention assurance that
protects required resources from concurrent application trash/reference release
during the supported offload operation. A bare existence check followed by a
separate device delete is insufficient. Define the hold/expiry/reconciliation
mechanism, including delayed OS confirmation and process death, before certifying
offload. Do not claim an atomic transaction across a server and the phone OS.
An uncertain or expired assurance blocks a new removal attempt.

Explain that durable server upload is not proof of independent backup against
disk failure, ransomware, or operator deletion. Surface the server's declared
recovery/backup health when available; do not invent a "safely replicated" badge.
The operator's retention guarantee and storage-failure assumptions must be clear.

On iOS, PhotoKit deletion affects the Photos library: with iCloud Photos it can
propagate to iCloud and other devices. There is no generic third-party
"evict only this phone's iCloud original" operation assumed here. Warn explicitly
before using library deletion; do not present it as device-only eviction.
Explain shared-library consequences where relevant. Android removal also follows
the selected media provider's supported semantics and OS consent, not a claim
that every provider's remote copies are untouched.

Respect OS deletion results and reconcile partial success, cancellation,
permission changes, and already-removed assets. OS Recently Deleted/trash may
continue consuming space; estimates are not guarantees of immediate reclamation.
Never silently empty an OS recovery bin to inflate reported savings.

### 3.13 C13 - Separate lifecycles and restoration

| Action | Effect |
|---|---|
| Free up phone space | Remove approved OS media copies; retain server originals |
| Server cleanup/trash | Remove selected server assets from normal/shared views; retain R33 recovery state |
| Evict app cache | Remove regenerable application previews/downloads; do not alter either media library |
| Export/restore to device | Explicitly create an OS-library copy; do not mark it as a new unbacked original merely by filename |

Local deletion, whether initiated by this app or elsewhere, does not delete the
backup. Server deletion does not instruct the app to erase an independently held
device original. A "delete from both" operation is not established scope.

Persist source-to-backup mappings and removal/import history independently of
the evictable cache. Reconcile server trash/deletion with still-present device
items: do not immediately reupload the same source revision and undo a user's
cleanup. Surface its state and require an explicit re-backup decision. New edits,
OS restores, missing history, and reinstall require reconciliation, not assumed
identity reuse or permission to delete.

Server restore follows R33 without reviving revoked grants. Device export may
have OS-limited fidelity; unsupported compound resources/edits must be identified.
Show how to retrieve server originals before suggesting local removal.

### 3.14 C14 - Bounded storage and caches

Maintain separate budgets for evictable thumbnails/previews, transient original
viewing/video buffers, pending-transfer staging, and durable operational metadata.
Apply byte limits, cleanup on completion/cancellation, memory-pressure handling,
and bounded prefetch. The original must not remain indefinitely in app storage
just because it was uploaded or viewed.

Track peak storage, not only steady state: exporting/chunk staging can temporarily
duplicate local bytes. Avoid staging an entire library; pause clearly when free
space is insufficient. Cache purge must not erase uncommitted uploads, source
mappings, review intents, or committed sync tokens.

Explicit offline-original downloads are a possible opt-in feature, not a default
or silently pinned cache. Their quota, removal, and revoked-access behavior need
separate UX approval. User-requested OS exports are not an application cache.
Bound metadata/page retention while preserving minimal correctness-critical state;
an unbounded full remote index is not required.

### 3.15 C15 - Offline and multi-client behavior

Render authorized committed cached state with an offline/stale indicator.
Unavailable originals show an explicit connection requirement, not a misleading
broken/empty gallery. Persist pending safe operations with IDs and base revisions;
indicate queued versus server-confirmed decisions.

Reconcile pending work with current authorization before replay. Phone removal
and server trash require online validation and confirmation; never replay a
destructive action against a newly expanded live selection. Pending keep feedback
does not claim to have protected media from another client until committed.

Partition views/tokens by server, account, library, filters, and access generation.
Use backend error/reset contracts rather than silently dropping data on a token
failure. Push and stale local state cannot bypass a restored deployment's epoch.
Already downloaded copies cannot be remotely guaranteed erased while offline.

### 3.16 C16 - Small-batch AI cleanup review

Use a dedicated review screen with a preview/detail sheet, not a blocking
startup modal. **Proposed batch size: 24 candidates**, always bounded to a few
dozen with lazy previews. The precise limit remains a UX decision.

Group/filter by backend reasons such as likely memes/forwards, screenshots, or
blur, showing coverage and uncertainty. Present sufficient detail to identify a
valuable blurred photo or useful receipt; a category score is not a verdict.
Do not hide candidates' full context behind an irreversible swipe.

Keep a stable bounded review session with candidate/asset/decision revisions.
Do not insert/reorder candidates under the user's finger when model output
arrives. Remove invalidated entries safely; refill at an explicit next-batch
boundary while preserving selection. Totals refer to a declared view revision.
No response means "unreviewed," not permission to delete.

### 3.17 C17 - Refusal, deferral, and confirmed cleanup

| Choice | Persisted meaning |
|---|---|
| Keep / not unwanted | Protect this asset from future cleanup suggestions until the user removes protection |
| Dismiss suggestion | Suppress the current assessment; rescans/model updates do not silently reintroduce it under R33 |
| Later / skip for now | Leave unreviewed and defer it from the active batch; do not train a negative or positive label |
| Move selected to server trash | Explicitly confirm a bounded asset/revision set through the backend |

Canceling a dialog, closing the screen, or losing the connection is not "keep"
feedback and is never deletion consent. Explain Keep versus Dismiss in the UI;
allow browsing/reversing those decisions and requesting an explicit reassessment.
Later uses a recorded revisit policy, not immediate reinsertion into the same
session; the exact time/next-session policy remains open.

Keep/dismiss/preferences synchronize privately through backend R33. A durable
review-resume/defer record must also prevent skipped items looping on another
device; it does not change machine classification. Decisions are independent of
blob deduplication and other users' opinions.

For server trash, show item count, logical bytes, recovery deadline, and any
permission/protection conflicts. Apply backend per-item outcomes, retain failed
selections for review, and offer authorized recovery. Explain that logical bytes
are not guaranteed physical space savings. This action does not implicitly
delete OS-library copies or free their space.

### 3.18 C18 - Status, navigation, and settings

Proposed navigation: **Gallery**, **Sharing**, **Backup**, **Review**, and
**Settings**. Phone-space cleanup belongs under Backup, with a shortcut from
storage status; server-trash recovery is distinct from the AI candidate list.
Exact navigation and visual design remain open.

Display backed-up versus verifying/pending/error counts for the permitted scope,
last successful catch-up, background restrictions, and cache/staging usage.
"All backed up" must say what scope and resource contract it covers.

Provide connection/discovery, account/sign-out, backup scope/pause, resource
policy, cache limits/clear, and cleanup protections as necessary control groups.
Expose missing permissions with actionable explanations, not repeated coercive
prompts. The complete settings inventory and defaults are a later design task;
diagnostic exports are opt-in and redact secrets/private media.

### 3.19 C19 - Security and native/UI boundary

Store credentials in platform secure storage with supported background-access
policy. Protect private persistence using platform data protection; exclude
reconstructible caches and sensitive credential material from inappropriate
device/cloud backup. Redact URLs with credentials, push tokens, filenames,
person labels, and media from ordinary logs/crash reports.

Namespace every task, notification, cache entry, and pending operation by server,
account, and installation generation. On sign-out/server switch, stop or safely
cancel old work, invalidate local authority, unregister push best effort, and
purge inaccessible cached views. Failure to contact the old server must not leave
its jobs running under the new account. Preserve a safe cleanup path for orphaned
OS tasks without exposing another user's content.

An untrusted backend response or push cannot select arbitrary local files, launch
OS deletion, invoke unrestricted native methods, or change the approved issuer.
If using a hybrid UI, bundle/trust its application code and expose a minimal typed
bridge; arbitrary backend-hosted HTML must not inherit native media/credential
capabilities. System login stays outside that WebView.

After revocation, purge cooperative cached views on the next validated response.
Do not promise instant recall of media already held on an offline or hostile
device. User-visible push alerts, if added, need separate privacy/permission UX.

### 3.20 C20 - Usability and accessibility

Support screen readers, scalable text, accessible selection, adequate touch
targets, reduced motion, and non-color-only status. Provide button alternatives
to rail dragging and swipe review. Confirmation clearly names phone removal
versus server trash, and never relies on a gesture alone for destructive consent.

Keep scrolling, selection, playback controls, and progress responsive during
hashing/export/sync. Preserve semantic anchors through orientation/grid changes.
Measure frame responsiveness, memory, battery, transfer/staging usage, and date
seek latency on representative supported devices and large-library fixtures.
Exact numerical budgets are release criteria still to be selected.

### 3.21 C21 - E2E testability and TDD

Extend backend R31 with isolated, provisioned accounts, real passkey/OIDC flows,
device media fixtures, and two independent client states. Drive supported
onboarding, transfer, browsing, sharing, review, and restore journeys through
client-visible interfaces, not database assertions alone.

Prefer TDD for transfer/review state machines, revision fencing, resource-set
completeness, cache budgets, and deletion eligibility. Test doubles can force
lost hints and process failure, but cannot certify actual PhotoKit/MediaStore
permissions, push delivery, background scheduling, or OS removal semantics.

Use simulators/emulators for repeatable journeys and selected real devices for
platform-specific acceptance. Exercise provider sandbox/test delivery where
available and a no-push profile. Assert eventual catch-up during permitted
execution, not a guaranteed silent-push delivery deadline.

Every C01-C21 requirement must map to executable test evidence for each supported
platform profile. UI/native framework selection is unacceptable if it prevents
E2E evidence for required behavior. Use causal statuses and deadlines, not fixed
sleeps or absence of queued work as proof of backup.
No client implementation or executable client suite exists yet; section 5 is
required future acceptance coverage, not a claim of passing tests.

## 4. Alternatives and open decisions

These options are recorded for discussion, not silently selected:

| Area | Alternatives | Trade-off / recommendation |
|---|---|---|
| Client implementation | Separate native apps; shared core; cross-platform or bundled hybrid UI | Swift with SwiftUI/UIKit selected for iOS MVP; Android strategy remains open. |
| Update transport | Push + HTTPS reconciliation; foreground SSE plus push; HTTPS-only foreground refresh and OS-scheduled catch-up | Recommend push + HTTPS for mobile, keep SSE optional and a no-push profile. No approach guarantees execution when the OS forbids it. |
| Phone removal | Reviewed free-space batches; opt-in automatic offload | Independent opt-in automatic backup and removal settings selected; actual scheduling/consent follows OS capabilities and backup-safety checks. |
| Discovery | Manual URL; DNS-SD suggestions; independently trusted QR pairing | Combine manual setup and optional discovery; pairing can simplify trust without treating advertisements as credentials. |
| Refused cleanup | Keep protection; dismiss assessment; later deferral | Offer distinct choices rather than treating every refusal as training feedback. |
| Media availability | Evictable previews only; explicitly pinned offline originals | Recommend bounded previews by default; pinned originals are optional, quota-accounted scope. |

Before implementation, decide minimum OS versions and app distribution/signing,
direct push versus optional relay operation, Android/code-sharing strategy, the
lossless media support matrix, offload retention assurance and OS consent UX,
review deferral semantics, numerical resource/quality budgets, and the complete
settings design. These are north-star implementation decisions, not permission
to weaken data safety or sync correctness.

## 5. Acceptance scenarios

1. **C02, C03, C19:** Configure a backend manually and through permitted discovery; deny local
   discovery permission, encounter two servers/spoofed advertisements, change
   networks, and reject wrong TLS/issuer identity without leaking credentials.
2. **C03, C19:** Provision and log in through the real identity provider; exercise passkey
   cancellation, token expiry, account disablement, and server/account switch.
3. **C04, C05:** Import with denied/limited/full OS permissions, expand/revoke access, and
   handle cloud-only or unsupported compound resources without false completion.
4. **C05, C10, C13:** Back up supported photos/videos, Live Photo/resource sets, and edits; verify
   byte identity and supported restoration. A missing required resource never
   makes the source eligible for removal.
5. **C06, C07:** Interrupt/reorder chunks, kill/restart the client, reboot, duplicate callbacks,
   expire uploads, and change the local source. Resume without duplicate logical
   attachments, stale completion, lost pending bodies, or UI blocking.
6. **C07, C08, C15:** Drop/collapse/reorder push hints, deny notifications, rotate push tokens, and
   run without push. Foreground/resume catch-up converges with current authority;
   no persistent connection or high-priority notification abuse is required.
7. **C09, C10, C15:** Browse at least one million assets spanning 20+ years, jump dates, and remove
   media above the viewport from another client. Preserve date/asset anchors,
   bounded pages, atomic deltas, and current authorization.
8. **C11, C19:** Share with eligible known recipients, distinguish duplicate names, disable a
   recipient mid-flow, revoke one of multiple grants, and verify provenance
   without exposing private annotations or identity-management APIs.
9. **C05, C12:** Propose phone cleanup only after fresh complete backup/retention validation.
   Race server trash, source edits, permission changes, expired assurance, and
   OS consent cancellation. Ineligible items remain local; server copies survive
   successful offload. Explain/test synchronized-library deletion consequences.
10. **C12, C13, C14:** Distinguish phone removal, cache purge, server trash, and explicit device
    restore. Do not reupload the same server-trashed revision automatically or
    accidentally erase a device original following a server event.
11. **C06, C07, C10, C14:** View large media and perform a large backup under low disk/memory conditions.
    Enforce budgets without evicting pending transfer bodies or correctness state;
    original viewing/upload does not create a permanently retained copy.
12. **C16, C17:** Review a bounded cleanup batch, skip/cancel/keep/dismiss, update decisions
    from another client, and rescan with a new model. Stable sessions, private
    feedback, preserved protection, and deliberate reassessment prevent loops.
13. **C13, C16, C17:** Confirm selected server-trash actions, handle partial conflicts, restore
    within retention, and verify that this does not silently remove device media
    or promise immediate local/physical space savings.
14. **C01, C15, C18, C19, C20, C21:** Exercise accessibility, orientation/grid changes, offline/pending states,
    background restrictions, and poisoned native-bridge inputs on each supported
    profile. Record real-device scheduling/permission evidence separately from
    simulator-only success.

## 6. Platform references

Platform behavior must be verified against the supported release matrix:

- [Apple: background push updates](https://developer.apple.com/documentation/usernotifications/pushing-background-updates-to-your-app)
  describes best-effort delivery and restricted background execution.
- [Apple: background URLSession transfers](https://developer.apple.com/documentation/foundation/downloading-files-in-the-background)
  describes OS-managed transfers and lifecycle callbacks.
- [Apple: deleting photos and videos](https://support.apple.com/en-us/104967)
  explains iCloud propagation and Recently Deleted behavior.
- [Android: background-task selection](https://developer.android.com/develop/background-work/background-tasks)
  distinguishes scheduled work, user-initiated transfers, and foreground services.
- [Android: network service discovery](https://developer.android.com/develop/connectivity/wifi/use-nsd)
  documents DNS-SD/NSD service discovery.
- [Android: shared media storage](https://developer.android.com/training/data-storage/shared/media)
  documents MediaStore, permissions, and OS-mediated media operations.
- [FCM: delivery priority](https://firebase.google.com/docs/cloud-messaging/customize-messages/setting-message-priority)
  distinguishes deferrable background sync from time-sensitive visible alerts.
