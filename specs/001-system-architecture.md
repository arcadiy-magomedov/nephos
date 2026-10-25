# System Architecture and Flows

## 1. Purpose and notation

This document illustrates the production north star in
[000 - Media platform](000-media-platform.md). Security analysis and proposed
additional controls are in [002 - Threat model](002-threat-model.md).

Boxes group ownership/trust boundaries, not machines. A home server can colocate
components; AKS or another cluster can distribute them. Databases, storage
engines, and network providers are configuration/adapters, not client contracts.
Arrows identify logical communication; they do not grant authorization.
Mobile behavior and unconfirmed UX recommendations are in
[003 - Native mobile client](003-mobile-client.md).

## 2. System and trust boundaries

```mermaid
flowchart TB
    subgraph callers["Untrusted client devices"]
        client["Web / native clients"]
        admin["Administrator browser"]
    end

    subgraph publicEdge["Public HTTPS boundary"]
        edge["Public gateway"]
        login["Public OIDC / enrollment endpoints"]
    end

    subgraph privateEdge["Authorized private network only"]
        privateGw["Private admin gateway"]
        console["Admin console / backend"]
        idAdmin["Identity management endpoints"]
    end

    subgraph pushEdge["Optional external OS push delivery"]
        push["APNs / Android provider or restricted relay"]
    end

    subgraph identity["Identity provider ownership"]
        idp["Auth server: OIDC and passkeys"]
        iddb[("Identity persistence")]
    end

    subgraph services["Private application network: authenticate service calls"]
        library["Library service: assets, grants, private reviews, journal, sync APIs"]
        upload["Storage / upload service: sessions, blobs, references, GC"]
        face["Face service: people and manual corrections"]
        search["Search service: generations and vector adapter"]
        curation["Curation service: cleanup assessments and scan generations"]
        publish["Library-owned gallery projection / publisher"]
        notify["Notification gateway: SSE / mobile push hints"]
        broker["Durable broker: pub/sub and work queues"]
        media["Media / verification workers"]
        faceWork["Face pipeline workers"]
        searchWork["Search pipeline workers"]
        curationWork["Curation pipeline workers"]
        infer["ML inference: bounded CPU / GPU capacity"]
    end

    subgraph persistence["Service-owned persistence and private storage"]
        libdb[("Library DB adapter: assets, grants, reviews, journal, publication state")]
        updb[("Upload DB adapter: sessions and references")]
        facedb[("Face DB adapter: observations and corrections")]
        searchdb[("Search persistence and vector DB adapter")]
        curationdb[("Curation DB adapter: assessments, models, scans")]
        blobAdapter["Storage adapters: volume / S3 / Azure Blob"]
        objects[("Originals, derivatives, retained gallery metadata")]
    end

    client -->|"HTTPS APIs and ranged media"| edge
    client -->|"OIDC / passkey ceremonies"| login
    admin -->|"Private network plus admin authentication"| privateGw
    privateGw --> console
    console -->|"Scoped provisioning"| idAdmin
    login --> idp
    idAdmin --> idp
    idp --> iddb
    console -->|"Management APIs, not direct DB writes"| library
    console --> upload
    console --> face
    console --> search
    console -->|"Scoped scan management"| curation
    edge --> library
    edge --> upload
    edge -->|"SSE connection"| notify
    notify -->|"Minimal coalesced hints"| push
    push -->|"Best-effort wake-up"| client
    library -->|"Authorized search"| search
    library -->|"Person resolution"| face
    library -->|"Scoped cleanup assessment queries"| curation
    curation -->|"Versioned assessments via owning API"| library
    library -->|"Acquire / release references"| upload
    library --> libdb
    upload --> updb
    face --> facedb
    search --> searchdb
    curation --> curationdb
    libdb -->|"Committed journal"| publish
    publish -->|"Commit published manifest frontier"| libdb
    publish -->|"Metadata objects and durable holds"| upload
    publish -->|"Only published revision hints"| notify
    notify -->|"Subscription authorization"| library
    library -->|"Outbox: committed AssetReady and changes"| broker
    upload -->|"Verification work and blob lifecycle events"| broker
    broker --> media
    broker --> faceWork
    broker --> searchWork
    broker --> curationWork
    faceWork --> face
    searchWork --> search
    curationWork --> curation
    faceWork --> infer
    searchWork --> infer
    curationWork --> infer
    search -->|"Bounded interactive inference scheduling"| infer
    media -->|"Scoped media reads / writes"| upload
    faceWork -->|"Scoped media reads"| upload
    searchWork -->|"Scoped media reads"| upload
    curationWork -->|"Scoped media reads"| upload
    upload --> blobAdapter
    blobAdapter --> objects
```

Only user-facing APIs, login, and SSE are routed publicly. No public route reaches
admin endpoints, databases, broker, provider management, or inference. The private
network is not an administrator role: identities and permissions remain required.
Login and identity management may be routes of the same identity provider; they
are separate exposure surfaces, not necessarily separate server installations.
Native clients use HTTPS catch-up after optional OS push hints; they do not
require an application-owned persistent connection. Push sending authority is
scoped to the configured app/build. Provider/relay failure never blocks core
backup, browsing, or synchronization during permitted client execution.

Each service owns its persistence. The library publisher is an internal library
component, not an independent service that writes another owner's database.
Broker connectivity is private and credentialed. Internal peer identity and
fine-grained authorization require the controls tracked in the threat model;
network placement alone is not sufficient.

Curation classifies potential cleanup candidates, not deletion commands. The
library owns private review decisions and checks current permissions before
exposing results. Only an explicit user-confirmed library command, with atomic
permission/protection checks, can move selected assets to recoverable trash.
Curation workers cannot delete assets or release references. Review changes use
private library projections and the existing durable sync contract; merely
flagging media never removes it from the ordinary gallery.

## 3. Upload, processing, and publication milestones

```mermaid
sequenceDiagram
    actor C as Client
    participant S as Storage / upload
    participant B as Durable broker
    participant V as Verification worker
    participant L as Library service
    participant P as Gallery publisher
    participant N as Notification gateway
    participant W as Media / face / search / curation workers

    C->>S: Authenticated intent, destination, size, optional hash
    S->>L: Check destination permissions / authorized reuse
    L-->>S: Current authorization decision
    alt Authorized existing content
        S->>L: Idempotent attachment / reuse workflow
        L-->>C: Authorized logical asset reference via API response
    else New upload session
        S-->>C: Session, part sizing, upload endpoints
        C->>S: Numbered parts, arbitrary order, retries
        C->>S: Finalize complete manifest
        S->>B: Durable verification job
        S-->>C: Operation accepted, status reference
        B->>V: Verification job
        V->>S: Read sealed bytes and commit verified result
        S->>L: Verified blob ready for idempotent attachment
        L->>S: Acquire durable asset reference
        S-->>L: Reference acquired
    end
    Note over S,L: Recoverable workflow across owners, no distributed DB transaction
    L->>L: Commit logical asset and journal / outbox
    L->>B: AssetReady after library commit
    B->>W: Independent pipelines with bounded consumers
    W->>L: Versioned metadata / processing outcomes
    L->>P: Committed ordered journal changes
    P->>S: Persist immutable nodes / segments and retention holds
    P->>L: Atomically publish complete manifest frontier
    P->>N: Published revision available
    N-->>C: library.changed hint on authenticated SSE stream
```

The asynchronous completion/status shape above makes queued verification
observable; exact API paths and failure-state enums belong in the upload
protocol specification. An upload verification event is not `AssetReady`.
Reusable blobs still require a committed logical asset or an explicitly
idempotent existing-asset result before downstream processing.

The sequence omits retries for readability, not correctness. Durable workflows,
reference holds, outboxes, and reconciliation must cover crashes between steps.
It does not imply the client keeps an HTTP request open during verification.

## 4. Versioned browsing and synchronization

```mermaid
flowchart LR
    journal["Commit-safe library journal"] --> projector["Ordered projection and publication"]
    projector --> manifest["Published manifest R: view and access generation"]
    manifest --> years["Year counts"]
    years --> months["Month counts"]
    months --> days["Day counts"]
    days --> segA["Bounded segment A version 3"]
    days --> segB["Bounded segment B version 1"]
    projector --> next["Published manifest R+1"]
    next --> unchanged["References to unchanged metadata versions"]
    next --> changed["Changed nodes and segment versions"]
    manifest --> delta["Atomic transition: base R to target R+1"]
    next --> delta
    delta --> clientCache["Client: stage parts, validate, commit model and sync token"]
    clientCache --> anchor["Rebase viewport using asset ID, sort key, and offset"]
    next --> hint["SSE hint: fetch durable changes"]
    hint -.-> clientCache
```

Both photo and video counts are maintained at each calendar level. Day grouping
does not bound transfer size: exceptionally large days contain multiple bounded
segments. Copy-on-write snapshots share unchanged metadata; they do not copy the
original photos/videos. Manifest publication occurs only after all dependencies
are durable.

SSE event IDs are not synchronization tokens. Clients use HTTPS for snapshots,
segments, deltas, and media, with polling recovery when SSE is unavailable.
Mobile clients can use the same durable APIs without SSE; OS push carries only
optional wake-up hints, not a replacement event log or guaranteed worker lease.
History expiry triggers an explicit anchored reset. Every read enforces current
authorization; retaining a snapshot never retains a revoked grant.

## 5. End-to-end test boundary

```mermaid
flowchart TB
    harness["Isolated E2E harness"] --> users["Two API client simulators and browser"]
    users --> routes["Real public / private ingress"]
    routes --> stack["Same application images and dependency implementations"]
    stack --> deps["Real identity, broker, DB, storage, vector, bounded model fixtures"]
    harness --> faults["Process / network / time-boundary fault controls"]
    faults --> stack
    stack --> outcomes["Authorized operations, revisions, bytes, and rendered anchors"]
    outcomes --> assertions["Deadline-based causal assertions"]
    stack --> evidence["Redacted logs, traces, correlation IDs"]
```

R31 requires real E2E evidence, supplemented by unit/property/adapter tests.
Controlled doubles are useful for some fault tests, but do not replace scenarios
with the selected real identity provider, storage, broker, and model execution.
No external biometric hardware or real family photos are required in ordinary
CI fixtures.
