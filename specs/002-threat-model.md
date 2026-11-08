# Media Platform Threat Model

## 1. Scope, status, and method

This is a design-time threat model of
[000 - Media platform](000-media-platform.md), using the trust boundaries and
flows in [001 - System architecture](001-system-architecture.md). No application
implementation exists in this workspace. Findings identify missing or unresolved
security contracts or residual implementation risks, not demonstrated
implementation vulnerabilities.
The [003 - Mobile client draft](003-mobile-client.md) extends the boundary to
device-library integration, discovery, OS push, and local-space reclamation.

The review uses STRIDE: spoofing, tampering, repudiation, information disclosure,
denial of service, and elevation of privilege. Resource-exhaustion scenarios are
included as resilience/abuse requirements rather than claims of proven exploits.

Control status:

- **Specified:** an adopted north-star contract; this is not implementation
  evidence.
- **Implementation evidence pending:** controls must pass R31 E2E and deployment
  acceptance before the system is certified.
- Provider names and implementation mechanics may remain open only when they
  preserve the specified behavior.

Severity estimates impact if the stated preconditions hold. Confidence measures
the evidence for the design gap, not the likelihood of exploiting future code.
Residual risks below assume the specified controls are implemented; they are not
accepted-risk decisions.

## 2. Assets and actors

| Asset | Security objective |
|---|---|
| Originals and all derivatives | Confidentiality, integrity, availability, authorized deletion and recovery |
| Assets, memberships, grants, upload provenance | Authoritative current access and attributable changes |
| Face observations, embeddings, names, aliases, corrections | Permission-scoped disclosure and editing |
| Cleanup assessments, private review decisions, trash and recovery deadlines | No implicit deletion, cross-user opinion leakage, or premature reclamation |
| Device-source mappings, backup receipts, offload holds, push registrations | No last-copy deletion, cross-account task reuse, or private notification leakage |
| Identity bindings, credentials, enrollment/recovery authority, sessions | Prevent impersonation and unauthorized enrollment |
| Manifests, counts, segments, journal, deltas, tombstones | Consistent publication without historical permission leakage |
| Upload sessions, parts, staging objects, reservations | Owner binding, integrity, bounded lifecycle |
| Jobs, events, generations, outputs | Authorized origin, replay safety, stale-write rejection |
| Workload identities, provider credentials, signing material | Least privilege and component confinement |
| Container/runtime/model artifacts | Authenticity and safe loading/execution |
| Backups and recovery metadata | Recoverability without resurrecting obsolete authority |
| Audit records | Reliable attribution without secret disclosure |

Device authentication biometrics stay on the device. Face-recognition data
derived from uploaded media is a different sensitive asset stored by the system.

Threat actors include unauthenticated internet attackers, provisioned malicious
users, malicious share recipients, stolen-session holders, compromised workers,
compromised artifact sources, private-network peers, and operators making
deployment or recovery mistakes.

Administrators, host operators, and chosen infrastructure providers have
substantial legitimate authority. Defending against a fully compromised host
administrator requires a different trust model; the current server processes
unencrypted media for ML. Private-network membership still never substitutes for
administrator authorization. Anonymous sharing and untrusted plugins are not
established features.

## 3. Trust boundaries

| Flow | Required boundary |
|---|---|
| Internet to public gateway | HTTPS and an explicit public-route surface, excluding management |
| Private network to admin gateway | Private reachability plus administrator authentication and authorization |
| Client through identity provider to application | Valid identity assertion plus enabled application membership |
| Gateway to library APIs | Resource authorization independent of network/gateway admission |
| Upload through staging and blob verification to asset publication | Verified bytes, current destination authority, durable reference before publication |
| Services through broker to workers | Authenticated producers/consumers; messages alone do not confer authority |
| Accepted media into parsers and inference | Hostile bytes remain untrusted after hash verification |
| Worker output to owning service | Schema, revision, generation, and write-authority validation |
| Published history/caches to clients | Old revisions never preserve revoked access |
| Storage service through adapter to provider | Physical credentials and locations remain behind the adapter |
| Artifact source to runtime | Integrity/provenance verification before loading |
| Backup to restored deployment | Reconcile security state, references, epochs, and pending work before reopening |
| Discovered backend to native client | Advertisement is not trust; verify approved TLS/server/issuer identity before sending credentials |
| OS push to client execution | Minimal hint only; fetch authoritative changes with current authorization |
| Verified server backup to OS-library removal | Complete resource evidence, fresh retention assurance, explicit user/OS consent, separate deletion domains |

The selected external transport is HTTPS plus web/optional foreground SSE and
optional native OS push hints. Raw TCP is not selected and does not add a current
attack surface.

## 4. Resolved north-star design findings

The previous review identified the following six design gaps. The main
specification now resolves each as a mandatory behavior contract. This closes
the specification decision, **not** implementation verification; the controls
remain release gates under R31.

| ID | Review severity | Source | Adopted design decision |
|---|---|---|---|
| F01 | HIGH | [R08/R09](000-media-platform.md#38-r08---passwordless-identity-and-biometrics) | Passkey-only; bound single-use activation; single-use offline recovery codes or audited administrator recovery with fresh admin passkey and verified out-of-band identity; revoke old credentials/sessions; never re-enable disabled membership |
| F02 | HIGH | [Processing isolation](000-media-platform.md#3241-untrusted-processing-isolation) | Hostile parsers and inference run isolated, non-root, with scoped read-only inputs, constrained output, default-deny egress and resource limits; verify artifact provenance before loading |
| F03 | HIGH | [R24](000-media-platform.md#324-r24---durable-pubsub-and-queued-processing) | Authenticated workload identities, broker/topic ACLs, job/attempt-scoped capabilities, and owning-service result validation; no ambient authority |
| F04 | HIGH | [R28](000-media-platform.md#328-r28---ownership-and-cloud-service-independence) | Quarantined restore, consistent recovery set, monotonic security epoch and protected revocation journal; fail closed if current authority cannot be proven |
| F05 | HIGH | [Artifact verification](000-media-platform.md#3241-untrusted-processing-isolation) | Immutable verified artifact references, controlled origins/update authority, no unverified executable model loading, offline verified weights |
| F06 | MEDIUM | [R19](000-media-platform.md#319-r19---face-recognition-clustering-and-names) | Annotations private per user/library view; explicit separate view/edit grants; identity/label state never inherited from deduplicated bytes |

## 5. Threat register and abuse acceptance

### T01 - Public exposure of administration

**STRIDE:** spoofing, elevation of privilege.

- **Preconditions/impact:** Incorrect routes, listeners, alternate ports, or
  forwarding trust expose management. Administrative compromise additionally
  requires stolen authority or an authorization failure.
- **Established:** Private-only administration, including identity management;
  administrator authorization and recent authentication.
- **Proposed:** Public-route allowlists, explicit trusted proxies, rejection of
  client-supplied identity headers, and independent exposure checks per platform.
- **Open/residual:** Ingress/provider route separation is unselected; private
  peers can still attempt attacks against private endpoints.
- **E2E:** Probe public IPv4/IPv6, ports, paths, hostnames, and forwarding headers
  from an external vantage. Even a valid admin token must not expose management
  publicly. Repeat across supported deployment profiles.

### T02 - Invalid identity assertions or stale sessions

**STRIDE:** spoofing, elevation of privilege.

- **Preconditions/impact:** Incorrect OIDC/WebAuthn validation or disabled-user
  enforcement admits the wrong identity or preserves access.
- **Established:** Keycloak OIDC tokens, QR enrollment and legacy PIN grants, short-lived
  access tokens, offline device sessions, API-side token introspection, and
  enabled application membership.
- **Implemented controls:** Validate issuer, audience, signature and expiry;
  validate the ID-token nonce on initial login; keep refresh tokens in Keychain;
  introspect each API request; fail closed with 503 on identity-service outage.
- **Implemented for new QR enrollments:** Sender-constrained renewable credentials
  whose theft alone does not permit renewal elsewhere, with crash/lost-response
  recovery that does not cause routine interactive login. DPoP-bound refresh
  tokens are implemented on server/iOS for bounded recovery; see R08 and C03. Require fresh proofs,
  key binding at issuance and recovery, replay rejection across replicas, and
  no silent bearer-only fallback. A strict one-use rotation toggle without a
  durable recovery path does not satisfy the persistent-login requirement.
- **Open/residual:** The 8-digit PIN is a short-lived bearer credential. A
  shoulder-surfer or compromised device can use it before consumption; a stolen
  valid device credential remains usable until that device session is revoked.
  Server and native Simulator DPoP qualification binds new QR refresh requests to the enrollment
  key. The shipped realm and existing-realm bootstrap require it for new QR
  enrollments; physical-device and live-deployment acceptance remain separate.
  The checked-in realm uses a finite 180-day inactivity timeout.
  Legacy sessions stay explicitly
  unbound rather than being silently reauthenticated or rebound. Refresh-only
  DPoP leaves short-lived access tokens as bearer credentials; full API
  proof validation is a separate scope decision. DPoP cannot protect against
  malicious code able to invoke the legitimate private key, and is not hardware
  attestation. Do not claim indefinite bearer tokens are protected merely because
  they are stored in Keychain.
- **E2E:** Reject wrong issuer/audience, invalid/expired/replayed PINs, disabled
  accounts and revoked sessions, including already-issued access and refresh
  tokens. Verify identity-service outages return retryable failures. Qualify
  stolen-token/wrong-key/replayed-proof rejection and delayed lost-refresh
  recovery against the real provider before claiming sender-constrained renewal.

### T03 - PIN login as account takeover (F01)

**STRIDE:** spoofing, elevation of privilege, repudiation.

- **Preconditions/impact:** Account substitution, PIN guessing or replay could
  issue OIDC tokens for another known user.
- **Specified/implemented:** Closed provisioning; account-bound 8-digit PINs,
  30-minute expiry, atomic one-use consumption, peppered HMAC verifier, ten
  attempts per account per 15 minutes, generic login errors, and no PIN in logs.
  Public email-only PIN requests validate known enabled users, bound input,
  enforce IP/email cooldowns and preserve active requests. Responses disclose
  expiry only. The private service-key list decrypts account-bound AES-GCM
  ciphertext from the same single-use record; consumption removes visibility.
  Correct PIN exchange directly returns normal OIDC tokens; it is not a
  passkey-enrollment-only grant.
- **Open/residual:** PIN delivery is in person and depends on the operator
  verifying the intended recipient. A screenshot or intercepted PIN can be
  used until expiry/consumption. The grant/provider SPIs are Keycloak-version
  coupled.
  The explicit unavailable-account request response permits enumeration; IP
  limits mitigate but do not eliminate distributed enumeration or request spam.
- **E2E:** Swap account identifiers, guess, race and replay PINs, disable users,
  revoke one device while preserving others, verify refresh and access token
  rejection, and ensure identity-service outages do not authorize requests.

### T04 - Inconsistent media and representation authorization

**STRIDE:** information disclosure, tampering, elevation of privilege.

- **Preconditions/impact:** Identifier substitution or inconsistent permission
  checks expose or modify an asset, original, derivative, or annotation.
- **Established:** Library authorization and selected-media grants apply across
  media representations; shared storage is not a grant.
- **Proposed:** An operation/representation authorization matrix covering
  downloads, crops, metadata, corrections, sharing, and mutations.
- **Open/residual:** Edit/download/resharing policy remains open. Authorized users
  can retain copies.
- **E2E:** Substitute cross-user identifiers on every read/write surface. Revoke
  one of multiple grants and verify only independently valid access survives.

### T05 - Upload substitution and finalization races

**STRIDE:** spoofing, tampering.

- **Preconditions/impact:** Manipulated sessions, parts, destinations, or replayed
  finalization corrupt or publish content without authority.
- **Established:** Authenticated intent, quotas, integrity checks, private staging,
  manifest validation, and protected finalization.
- **Proposed:** Bind operations/idempotency keys to actor, session, and
  destination; freeze accepted parts during verification; revalidate publication
  authority; generate physical keys server-side rather than trusting filenames.
- **Open/residual:** Adapter and direct-upload capability enforcement needs
  verification. Correct hashes do not make parser inputs safe.
- **E2E:** Cross-user resume/abort/finalize, swapped or expired upload URLs,
  conflicting parts, changed destinations, concurrent completion, path-like
  names, and crash/retry boundaries.

### T06 - Hostile media compromises processing (F02)

**STRIDE:** elevation of privilege, information disclosure, tampering.

- **Preconditions/impact:** An accepted upload triggers a decoder, extractor,
  transcoder, or model-runtime vulnerability. Impact follows worker authority.
- **Specified:** Queued work, resource budgets, scoped input access, and an
  explicit sandbox boundary: nonprivileged parser execution,
  read-only input, constrained output, no host/container-runtime socket, no
  provider/admin credentials, restricted filesystem/egress, dropped
  unnecessary capabilities, and restrictive syscall policy. Separate
  scheduler authority from parser execution.
- **Implementation choices:** Runtime/decoder and sandbox mechanism must meet
  the invariant on every certified platform; sandbox escapes remain possible.
- **E2E:** Malformed media fails safely. Instrumented parser processes attempting
  unrelated reads, provider access, internal API calls, or external egress are
  denied. Validate output schemas before authoritative publication.

### T07 - Hash deduplication leaks private existence or bytes

**STRIDE:** information disclosure, spoofing, tampering.

- **Preconditions/impact:** Guessed digests or shortcut behavior disclose another
  user's media or attach unauthorized content.
- **Established:** Verified whole-file hashes; no unauthorized shortcut; full
  upload before private cross-user reuse; atomic canonicalization.
- **Proposed:** Avoid existence signals in response shape and physical-savings
  quota responses; revalidate reuse at publication; choose deduplication scope
  together with encryption/key-domain and erasure policies.
- **Open/residual:** Timing side channels need measurement. Possessing identical
  bytes legitimately allows an independently owned asset.
- **E2E:** Known/unknown private digests reveal neither bytes nor an API existence
  signal. Race revocation and identical uploads. Independent assets survive
  another owner's share revocation.

### T08 - Reference and garbage-collection races

**STRIDE:** tampering.

- **Preconditions/impact:** Forged/replayed release operations or an acquisition/GC
  race destroy another asset's bytes or a retained manifest's dependencies.
- **Established:** Authoritative references, durable holds, coordinated GC,
  recovery workflows, and reconciliation.
- **Proposed:** Bind reference operations to owning entities/services, fence
  acquisition against deletion, and deny workers release authority over
  unrelated permanent references.
- **Open/residual:** Adapter conditional-operation behavior needs evidence;
  out-of-band provider deletion needs backup recovery.
- **E2E:** Interleave last release, new acquisition, worker/history holds, GC,
  crash, and replay. Assert surviving bytes and digest, not only counters.

### T09 - Excessive internal worker authority (F03)

**STRIDE:** spoofing, elevation of privilege, information disclosure.

- **Preconditions/impact:** A compromised worker/private peer uses absent or
  broad internal authorization to read unrelated media or mutate authority.
- **Specified:** Authenticated workload identities and narrowly scoped
  authority bound to
  job, blob/representation, operation, audience, expiry, and attempt. Separate
  scheduler, parser, storage, library, and administrative identities. Broker
  producers/consumers have topic ACLs.
- **Implementation choices:** Capability/workload-identity mechanism can vary
  if it meets the E2E contract. A compromised worker can still access its
  permitted input.
- **E2E:** Reject unrelated blob reads, grant mutations, permanent-reference
  releases, alternate-audience tokens, and management calls. Network location
  alone never authorizes an operation.

### T10 - Forged jobs and stale output publication

**STRIDE:** spoofing, tampering, repudiation.

- **Preconditions/impact:** Unauthorized messages or delayed results target
  another asset or resurrect cancelled/deleted/retired state.
- **Established:** Outbox, idempotency, durable acknowledgements, cancellation,
  deletion, and generation checks.
- **Specified:** Broker producer/consumer identities and topic ACLs,
  authenticated transport, validated schemas, owning-service checks, and
  revision/generation/attempt fencing. Jobs cannot introduce arbitrary
  commands, model sources, or fetch destinations.
- **Implementation choices/residual:** Broker and output-fencing mechanisms
  must meet the contract; compromised authorized producers retain their
  permitted scope.
- **E2E:** Wrong publisher, modified target, duplicate/replayed messages, restore,
  cancellation, deletion, and retired generations cannot produce unauthorized
  reads or stale publication.

### T11 - Retained history and caches preserve revoked visibility

**STRIDE:** information disclosure, tampering.

- **Preconditions/impact:** Old manifests, cursors, tombstones, segments, or cache
  validators disclose revoked content or chronology.
- **Established:** Current authorization, access generations, incompatible-view
  rejection, scoped removals, and stable authorized routes.
- **Proposed:** Integrity-protected tokens; authorization before conditional
  `304` responses; authorization-scoped cache keys/validators; no public caching
  or direct provider exposure of private metadata.
- **Open/residual:** Cache/token mechanisms need definition. Downloaded data
  cannot be recalled.
- **E2E:** Replay old manifests, segments, cursors, deltas, ETags, and ranges after
  revocation. Removals expose only previously authorized scope, not current
  private fields or stale counts.

### T12 - Streams or delivery URLs outlive authority

**STRIDE:** spoofing, information disclosure.

- **Preconditions/impact:** SSE subscriptions survive revocation or bearer
  delivery URLs bypass current authorization.
- **Established:** Stream expiry/revocation, independent request authorization,
  origin/CORS policy, bounded URL validity, and no long-lived event-URL tokens.
- **Proposed:** Explicit revocation-completion semantics, no stream caching or
  credential logging, and an authorization-checking delivery gateway wherever
  immediate per-request revocation is required.
- **Open/residual:** Delivery/session policy remains open. Independently valid
  bearer URLs can remain usable until expiry; already transferred bytes remain.
- **E2E:** Revoke/expire credentials during SSE and ranged downloads, reconnect
  with old authority, attempt hostile origins/scopes, and exercise proxy caches.

### T13 - Person annotations cross ownership boundaries (F06)

**STRIDE:** information disclosure, tampering.

- **Preconditions/impact:** Shared blobs, clusters, aliases, or merge redirects
  accidentally inherit another user's annotation visibility/edit authority.
- **Specified:** Labels and corrections are private to the annotating user's
  library view by default; explicit grants govern viewing/editing. Authorization
  covers observations, labels, aliases, redirects, merges, negative matches, and
  correction history, independent of canonical blob identity. Shared recipients
  create their own annotations unless the owner explicitly grants annotation
  visibility.
- **Residual:** Sharing a recognizable face necessarily permits human recognition.
- **E2E:** Independently uploaded identical bytes get different private labels.
  Search, suggestions, shares, merges, revocation, and reprocessing retain
  isolation.

### T14 - Provider access bypasses application authorization

**STRIDE:** information disclosure, elevation of privilege, tampering.

- **Preconditions/impact:** Public object ACLs, broad IAM, exposed credentials, or
  unsafe filesystem resolution bypass library permissions.
- **Established:** Private storage, internal provider locations, authorized APIs.
- **Proposed:** Least-privileged adapter identities; credentials confined to
  adapters; private ACLs; authenticated encrypted network transport; generated
  keys; path/symlink escape resistance; rotation and key-custody policy.
- **Open/residual:** IAM, encryption, secrets delivery, and filesystem privileges
  need configuration. A compromised storage administrator retains broad access.
- **E2E:** Direct unauthenticated access fails; clients/workers cannot list or
  delete provider objects; rotation works; filesystem escapes fail; responses,
  logs, and events contain no provider secrets.

### T15 - Artifact substitution or executable model loading (F05)

**STRIDE:** tampering, elevation of privilege.

- **Preconditions/impact:** Substituted images/models or executable model-loading
  behavior introduce attacker code.
- **Specified:** Approved artifact origins, immutable verified references,
  provenance/signature or trusted-hash verification, controlled updates,
  restricted executable model loading, and read-only verified model caches.
- **Implementation choices:** Registries/runtime/model formats must preserve
  verification. Compromise of an approved maintainer remains possible.
- **E2E:** Alter artifacts or request unapproved loader code; install/startup
  rejects them. Verified artifacts support offline operation.

Embedding inputs are data, not tool instructions. No prompt-injection
vulnerability is established for the current architecture; future generative
or tool-enabled features need separate assessment.

### T16 - Restore resurrects revoked authority (F04)

**STRIDE:** spoofing, tampering, information disclosure.

- **Preconditions/impact:** A backup predates account disablement, credential
  revocation, or share removal; reopening silently restores unwanted access.
- **Specified:** Restore privately with normal clients, processing, broker
  consumption, and GC disabled. Recover a documented consistency point and
  reconcile credentials/memberships/grants before exposure. If current security
  state is unavailable, require reapproval/re-enrollment. Invalidate old sessions,
  delivery capabilities, and job epochs as applicable.
- **Implementation choices:** Backup/identity mechanisms must satisfy R28.
  Unrecorded post-backup changes cannot be reconstructed; the specified fallback
  is quarantine and explicit reapproval, not silent restoration.
- **E2E:** Back up, revoke users/credentials/shares, restore, and confirm authority
  does not silently return. Reject old jobs/tokens and preserve valid
  media/reference relationships.

### T17 - Privileged actions lack attributable evidence

**STRIDE:** repudiation, tampering.

- **Preconditions/impact:** Sensitive changes cannot be investigated, attributed,
  or reconciled during recovery.
- **Established:** Auditable administration and provisioning.
- **Proposed:** Actor/workload, action, resource, outcome, correlation ID,
  revision, and epoch in protected audit records. Exclude authentication secrets
  and prevent ordinary workers altering audit history.
- **Open/residual:** Sink, retention, and recovery integration need selection;
  host compromise can defeat local-only auditing.
- **E2E:** Credential/grant changes, recovery, retries, GC overrides, and restore
  produce attributable records without secret leakage.

### T18 - Resource amplification and exhaustion

**STRIDE:** denial of service.

- **Preconditions/impact:** Large/hostile uploads, repeated expensive operations,
  excessive connections, or decoder expansion consume finite storage, CPU/GPU,
  memory, or network capacity.
- **Established:** Quotas, bounded queues/concurrency, incremental scheduling,
  deadlines, and finite SSE buffers.
- **Proposed:** Enforce declared versus actual bytes, part counts, concurrent
  reservations, decoded dimensions/frames/duration, intermediate-output size,
  parser deadlines, retry ceilings, and per-actor admission budgets. Include
  storage/broker/snapshot growth, not only worker CPU.
- **Open/residual:** Profile-specific capacities and fair scheduling need
  measurable budgets. Rate/resource limits mitigate abuse, not infinite demand.
- **E2E:** Retries cannot multiply reservations, direct/proxied uploads enforce
  equivalent limits, cleanup cannot reclaim another session, large reindexing
  preserves interactive capacity, and slow streams cannot grow memory unbounded.

### T19 - Cleanup suggestions become destructive authority

**STRIDE:** spoofing, tampering, information disclosure, elevation of privilege.

- **Preconditions/impact:** Forged/stale candidates, substituted asset IDs,
  cross-user feedback, or a compromised classifier trigger unauthorized removal,
  expose private review decisions, or defeat recovery. Ordinary classification
  mistakes are also a data-loss risk, not evidence of an exploitable model.
- **Specified:** R33 treats assessments as advisory data. Keep/dismiss state and
  preferences are private; media sharing and deduplicated bytes do not transfer
  them. Only explicit user confirmation of bounded assets/revisions, with fresh
  permission and protection checks, authorizes trash. Classifiers have no delete
  authority. Recovery deadlines retain references, and restore never revives
  revoked grants. Savings estimates cannot reveal other users' references.
- **Residual:** Users can still confirm an unwanted deletion; quality measurement,
  reasons, protected assets, and recoverable trash reduce but cannot eliminate
  mistakes. Already authorized/downloaded previews cannot be recalled.
- **E2E:** Forge another user's candidate/action, race keep/revocation with bulk
  confirmation, replay stale classifier results, and restore against GC expiry.
  Verify private decisions stay isolated, no automatic deletion occurs, restored
  media retains current authorization, and independent blob references survive.

### T20 - Mobile trust confusion and unsafe phone offloading

**STRIDE:** spoofing, tampering, information disclosure, elevation of privilege.

- **Preconditions/impact:** A spoofed advertisement or endpoint change steals
  credentials; stale/incomplete backup evidence removes the last usable original;
  push or a native bridge induces unintended actions; old installation work runs
  under a different account.
- **Specified:** Client C02/C19 require verified server/issuer identity and scoped
  native capabilities. C05/C12 require complete resource/revision evidence, fresh
  retention assurance, and explicit OS-aware local removal. Neither a push nor a
  server tombstone authorizes device deletion. Tasks, cache, registrations, and
  pending operations are bound to the approved server/account/installation.
  Provider payloads contain no private media content or credentials.
- **Implementation choices/residual:** UI/native framework, push distribution,
  and offload-hold mechanics require acceptance evidence. OS library deletion can
  propagate to an existing photo-cloud service; private caches already downloaded
  to an offline device cannot be remotely guaranteed erased. Server retention is
  not protection against a compromised host or unrecoverable storage failure.
- **E2E:** Spoof discovery/issuer data, swap accounts mid-transfer, revoke limited
  permissions, omit a compound resource, race server deletion with phone removal,
  expire an offload assurance, and replay hints/native commands. Ineligible items
  stay local; successful offload preserves server resources and reports OS
  cancellation/partial outcomes accurately.

## 6. Security evidence and release gates

Apply R31 to these threats. Prefer a failing abuse test before implementing a
specified control. Test both rejection and absence of forbidden effects: no
disclosed bytes, changed grants, released references, enrolled credentials, or
stale outputs.

Fixtures include two owners, selected sharing, overlapping grants, a disabled
account, independent copies of identical bytes with private face labels, and
distinct workload identities. Use controlled clocks, barriers, and process/network
faults rather than sleeps. Exercise real supported identity, broker, and storage
integrations; mocked authorization alone is not E2E security evidence.

| Release gate | Threat coverage | Responsible boundary |
|---|---|---|
| Private management and valid identity | T01-T03 | Gateway, identity, admin, library |
| Representation and person isolation | T04, T11-T13 | Library, face, cache, delivery |
| Safe ingestion and references | T05-T08, T18 | Upload, storage, media processing |
| Confined workers and authentic work | T09-T10 | Workload identity, broker, owning services |
| Provider and artifact integrity | T14-T15 | Storage adapters, release, ML |
| Security-preserving restore and audit | T16-T17 | Operations and state-owning services |
| Advisory cleanup and recoverable removal | T19 | Curation, library, storage, client synchronization |
| Mobile trust and last-copy safety | T20 | Native adapters, session/transfer coordinator, library, storage, notification adapters |

## 7. Decision register

| Decision required | Needed before | Owner |
|---|---|---|
| Select provider and activation delivery meeting passkey-only recovery | Production identity acceptance | Identity, admin, library |
| Select sandbox runtime satisfying parser/job-capability contracts | Processing untrusted media | Media/ML platform |
| Select workload identity, broker ACL, and output-fencing mechanisms | Distributed processing acceptance | Service platform and owning services |
| Implement protected journal/epoch, backup consistency, and quarantined restore | Recovery certification | Operations and state owners |
| Select trust roots and safe model-loading formats | Executing release/model artifacts | Release and ML platform |
| Implement per-user/library annotation grants | Shared face-feature acceptance | Face and library |
| Deduplication scope, key domains, erasure | Storage/encryption implementation | Storage and library |
| Delivery revocation semantics | Delivery-mode certification | Gateway, library, storage |
| Provider IAM, key custody, adapter confinement | Provider certification | Storage and operations |

The six previously identified design findings are resolved as contracts in the
main specification. This threat model remains active: other proposed controls
and residual risks require detailed review, and no contract is implemented or
proven merely because it is documented. Certification requires the corresponding
E2E evidence on every supported deployment profile.
