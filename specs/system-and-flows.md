# System and UX state machines

These diagrams describe the current implementation, not every roadmap feature.
The system diagram shows deployed components (dashed arrows mark optional
services or unshipped native UI). Every UX flow is modeled as a finite state
machine (`stateDiagram-v2`) grounded in the actual code. See
[implementation scope](media-api.md).

## System

```mermaid
flowchart LR
    phone["Native iOS app"]
    client["Authorized API client"]
    operator["Administrator on private endpoint"]
    https["Trusted HTTPS endpoint: Caddy TLS overlay or external proxy"]

    subgraph host["Self-hosted Docker Compose deployment"]
        ingress["NGINX media gateway"]
        identity["Keycloak: known users and device sessions"]
        library["Library API: access, gallery and sharing"]
        storage["Storage API: uploads and originals"]
        verifier["Upload verification and publication worker (storage-worker)"]
        broker["RabbitMQ: durable ready events"]
        projection["Library worker: projection and face outbox"]
        admin["Private admin console"]
        adminapi["Private Library administration"]
        sessions["Valkey: operator sessions"]
        cleanup["Scheduled cleanup"]
        media[("Media volume: originals and previews")]
        renderer["Thumbnail and preview service (image-derivatives)"]

        subgraph databases["One PostgreSQL server, separate databases and roles"]
            identitydb[("Keycloak database")]
            librarydb[("Library database")]
            storagedb[("Storage database")]
        end

        subgraph faces["Optional owner-private face service"]
            faceapi["Faces API"]
            faceworker["Faces worker"]
            facedb[("Separate Faces PostgreSQL")]
            inference["Private CPU inference workers"]
        end

        subgraph monitoring["Optional observability profile"]
            collector["OpenTelemetry Collector"]
            telemetry["Prometheus, Loki and Tempo"]
            grafana["Grafana"]
        end
    end

    phone --> https
    client --> https
    https --> ingress
    ingress --> identity
    ingress --> library
    ingress --> storage
    ingress -.-> faceapi
    operator --> admin
    admin --> identity
    admin --> adminapi
    admin --> sessions
    adminapi --> librarydb
    adminapi --> identity
    identity --> identitydb
    library --> librarydb
    library -->|"authorized content"| storage
    storage -->|"access check"| library
    library -->|"live token validation"| identity
    storage -->|"live token validation"| identity
    storage --> storagedb
    storage --> media
    storage --> renderer
    verifier --> storagedb
    verifier --> media
    verifier --> renderer
    verifier --> broker
    broker --> projection
    projection --> librarydb
    projection -.->|"eligible primary photos"| faceapi
    faceapi --> facedb
    faceapi -->|"owner and asset checks"| library
    faceapi -->|"live token validation"| identity
    faceworker --> facedb
    faceworker -->|"authorized original"| storage
    faceworker -->|"owner and source check"| library
    faceworker --> inference
    cleanup --> library
    cleanup --> storage
    cleanup -.-> faceapi
    library -.-> collector
    storage -.-> collector
    collector --> telemetry
    telemetry --> grafana
```

Public ingress never exposes internal APIs or administration. Media authority
comes from Library references, not a blob hash. Workers have durable database
outbox state; preview generation never modifies originals. Faces and monitoring
are independently optional. Books/cinema apps, semantic search and Kubernetes
deployment are future work, not hidden services in this diagram.

## 1. Admin provisioning and QR invitation state machines

### 1a. Durable administrative operations

Models `administration_operations` (`provision`, `profile`, and `access` commands)
in `PostgresAdministrationOperations.cs` and `AdministrationWorker.cs`.

```mermaid
stateDiagram-v2
    [*] --> Pending : POST command accepted [idempotent ID, access sets Library enabled=false immediately]

    Pending --> Running : Worker claims lease [next_attempt_at <= now, 90s lease]
    Running --> Running : Lease expired [another worker reclaims]

    Running --> Pending : Intermediate step advanced [provision reserved to identity-created to library-created, access enable reserved to identity-created]
    Running --> Completed : Final step committed [step=completed, Library principal updated]
    Running --> Pending : Transient error [5xx/429/network/DB, backoff <= 300s]
    Running --> Failed : Permanent error [409 conflict or 4xx identity rejection]

    Failed --> Pending : Operator clicks Retry safely [profile/access rebases revision if conflict]
    Failed --> Abandoned : Operator clicks Abandon [profile, access, or unstarted reserved provision]

    Completed --> [*]
    Abandoned --> [*]

    note right of Abandoned
        Abandoning an unstarted provision releases the
        reserved login. Abandoning access leaves the user
        disabled in Library until explicitly re-enabled.
        Started provisions (identity-created/library-created)
        must retry to completion.
    end note
```

### 1b. Single-use QR invitation lifecycle

Models `EnrollmentResource.java`, `QrGrant.java`, `EnrollmentStore.java`, and
the admin console polling UI (`invitation.html` / `invitation.js`).

```mermaid
stateDiagram-v2
    [*] --> Active : Admin issues QR [user enabled, active invites < 10, 10m TTL]

    Active --> Used : Device exchanges valid QR + challenge + DPoP [creates offline session + 10m recovery receipt]
    Active --> Expired : 10m TTL elapsed [now >= expiresAt]
    Active --> Cancelled : Admin cancels QR [DELETE invitation]
    Active --> Revoked : User disabled or epoch advanced

    Used --> Used : Same device + key + binding retries [within 10m deliveryUntil and session still valid]
    Used --> UsedReceiptExpired : 10m recovery window elapsed [receipt scrubbed, session stays active]
    Used --> Revoked : Linked session revoked or user disabled [receipt deleted]
    Used --> Used : Admin DELETE rejected with 409 [preserves receipt and active session]

    Expired --> [*]
    Cancelled --> [*]
    Revoked --> [*]
    UsedReceiptExpired --> [*]

    note right of Revoked
        Admin console and invitation.js treat revoked as
        a terminal state, hide the QR code, and stop polling.
    end note
```

## 2. iOS enrollment and persistent session state machine

Models `SignInModel.Screen` (`SignInModel.swift`), `AppRootView.swift`,
`SignInView.swift`, `QREnrollmentClient.swift`, and `OAuthResponse.tokens`.

```mermaid
stateDiagram-v2
    [*] --> Restoring : App launch

    Restoring --> Welcome : Vault empty [no session, no pending enrollment]
    Restoring --> Connecting : Vault has pending enrollment [same installationID]
    Restoring --> SignedIn : Vault has saved session [shows local Photos immediately, validates async]
    Restoring --> Recovery : Keychain unreadable or pending identity mismatch

    Welcome --> Scanner : Tap Scan QR code
    Welcome --> Connecting : Import QR image from Photos

    Scanner --> Welcome : Tap Cancel or app backgrounds
    Scanner --> Connecting : Camera decodes QR payload
    Scanner --> QrError : Camera permission or scanner error

    QrError --> Scanner : Tap Scan again
    QrError --> Connecting : Choose QR from Photos

    Connecting --> SignedIn : Exchange + Keychain commit succeeded [even if post-commit check hits transient outage]
    Connecting --> QrError : Invalid QR/image or invalidating server error [clears pending]
    Connecting --> Recovery : Transient outage, lost response, or non-invalidating error [vault.pending kept]

    state SignedIn {
        [*] --> Connected : Validation ok [message empty]
        Connected --> LocalOnlyNotice : Transient outage or unrecognized 4xx/5xx [shows Retry connection]
        Connected --> AccessDisabledNotice : Library returns 403 Forbidden [shows Access disabled + Retry/Sign out]
        LocalOnlyNotice --> Connected : Retry connection or foreground return succeeds
        AccessDisabledNotice --> Connected : Account re-enabled and retry succeeds
        LocalOnlyNotice --> LocalOnlyNotice : Retry fails again [local Photos stays usable]
        AccessDisabledNotice --> AccessDisabledNotice : Account remains disabled [local Photos stays usable]
    }

    SignedIn --> Welcome : Validation or upload receives ClientError.signedOut [stops uploads, clears Keychain]
    SignedIn --> Welcome : Remote sign-out revoked OR device-only sign-out [clears Keychain]
    SignedIn --> Recovery : Remote sign-out failed or Keychain removal failed

    Recovery --> Connecting : Tap Retry [replays saved pending enrollment or restores session]
    Recovery --> SignedIn : Tap Retry [vault.current restored]
    Recovery --> Welcome : Cancel sign-in [no saved session] or device-only sign-out [clears Keychain]
    Recovery --> Recovery : Remote sign-out fails [or vault.current is nil]

    note right of Recovery
        DPoP proof errors map to invalidProof and preserve
        vault.pending until Retry succeeds or the user
        explicitly chooses Cancel sign-in.
    end note
```

There is no public registration, manually entered upload URL, or per-renewal
biometric prompt.

## 3. Automatic backup and server upload state machines

### 3a. iOS upload item and growing batch

Models `UploadPhase` (`UploadPhase.swift`), `UploadCoordinator.swift`,
`SQLiteUploadRepository.swift`, `UploadModel.swift`, and `UploadsView.swift`.

```mermaid
stateDiagram-v2
    [*] --> Queued : Photos discovery adds asset to open batch [Live Photo = 1 item]

    Queued --> Succeeded : Restore existing complete remote manifest + backup evidence
    Queued --> Preparing : Active transfers < 16 and network policy allows
    Queued --> Failed : Discovery error [missing/duplicate PhotoKit resources]

    Preparing --> Scheduled : Exported + hashed, upload intent created, chunks enqueued
    Preparing --> Verifying : All chunks already confirmed or server returned verifying
    Preparing --> Succeeded : All resources ready + resource-set manifest committed
    Preparing --> Failed : Export error, Photos modified/deleted, or non-retryable error

    Scheduled --> Uploading : Background URLSession sends bytes [receivedBytes > 0]
    Scheduled --> Verifying : Final chunk confirmed + complete called
    Scheduled --> Failed : Non-retryable receipt [400/403/404/413/415/507] or attempts >= 5
    Scheduled --> Queued : Policy changed to disabled or Pause all cancels transfers

    Uploading --> Verifying : All chunks confirmed + POST /complete accepted
    Uploading --> Scheduled : Network drop, policy change, or retryable chunk failure [backoff <= 300s]
    Uploading --> Failed : Non-retryable receipt, server failed/cancelled, or attempts >= 5

    Verifying --> Succeeded : All resources report ready + PUT resource-set manifest succeeds
    Verifying --> Failed : Server verification failed or manifest conflict

    Failed --> Queued : User taps Retry failed [sets needsRestart=true, clears attempts]
    Failed --> Queued : Photos asset modified [new sourceRevision replaces failed row]

    Succeeded --> [*] : Batch closes only when reconciliation finds 0 pending and 0 failed

    note right of Queued
        Resume all stays enabled whenever paused=true, and
        changing upload policy clears paused. 401 chunk
        receipts acknowledge before token refresh, and
        ClientError.signedOut halts uploads and signs out
        without marking pending items Failed.
    end note
```

### 3b. Server upload resource and publication

Models `uploads.state` in `PostgresUploadRepository.cs`, `UploadWorker.cs`,
`ProjectionWorker.cs`, and `PostgresResourceSetRepository.cs`.

```mermaid
stateDiagram-v2
    [*] --> Uploading : POST /v1/uploads [quota + headroom ok, no deleting fence]
    [*] --> StoredPendingProjection : POST /v1/uploads [same owner/library duplicate with resourceSetId, copies ref + outbox]
    [*] --> Ready : POST /v1/uploads [standalone duplicate with no resourceSetId, returns existing ID]

    Uploading --> Uploading : PUT /parts/index [immutable 4 MiB chunk, identical retry idempotent]
    Uploading --> Verifying : POST /complete [all parts present]
    Uploading --> Failed : DELETE /uploads/id [cancelled by uploader]
    Uploading --> Failed : Idle > 24h [UploadWorker cleanup]

    Verifying --> Verifying : Verify lease expired [5m lease reclaimed] or blob deleting fence active [lease released]
    Verifying --> StoredPendingProjection : Length + SHA-256 verified, previews staged, ref + outbox committed
    Verifying --> Failed : Length or SHA-256 mismatch [UploadConflictException]

    StoredPendingProjection --> StoredPendingProjection : Outbox retry [RabbitMQ unavailable]
    StoredPendingProjection --> Ready : RabbitMQ confirm + Library ProjectionWorker commits asset [API reports verifying until then]

    Ready --> VisibleInGallery : Standalone upload OR PUT resource-set manifest commits all constituents [primary visible, companions hidden]

    Failed --> Uploading : POST /retry [clears parts/staging, rechecks quota + headroom]

    VisibleInGallery --> [*]
```

## 4. Local iOS gallery and media viewer state machine

Models `LocalMediaLibrary.swift`, `LocalGalleryView.swift`, and
`MediaViewer.swift`. Remote cloud browsing, People, Search and Shared filters
are not shipped in the iOS app.

```mermaid
stateDiagram-v2
    [*] --> CheckingPermission : Enter signed-in Library

    CheckingPermission --> NotDetermined : PHAuthorizationStatus.notDetermined
    CheckingPermission --> Denied : PHAuthorizationStatus.denied
    CheckingPermission --> Restricted : PHAuthorizationStatus.restricted
    CheckingPermission --> Gallery : authorized or limited [limited shows Manage banner]

    NotDetermined --> Gallery : Allow Photos access granted
    NotDetermined --> Denied : Allow Photos access denied
    Denied --> CheckingPermission : Return from system Settings
    Restricted --> [*] : Read-only restriction message

    state Gallery {
        [*] --> Browsing : Filter All / Photos / Videos [Shared disabled]
        Browsing --> Browsing : Switch filter, load more, or Manage limited selection
        Browsing --> Viewer : Tap thumbnail [Photo, Live Photo, or Video]

        state Viewer {
            [*] --> Viewing : Swipe prev/next or zoom/play
            Viewing --> PreparingShare : Tap Share [exports originals]
            PreparingShare --> ShareSheet : Export ready
            PreparingShare --> Viewing : Tap Cancel sharing or export error alert
            ShareSheet --> Viewing : Dismiss sheet [deletes temp export dir]

            Viewing --> AppDeleteConfirm : Tap Delete [canDelete=true]
            AppDeleteConfirm --> Viewing : Tap Cancel
            AppDeleteConfirm --> DeletingPhotos : Tap Delete from Photos
            DeletingPhotos --> Viewing : System Photos prompt cancelled [userCancelled]
            DeletingPhotos --> Viewing : Deleted and neighbor exists [advances to neighbor]
            DeletingPhotos --> Viewing : Delete error alert [asset still present in Photos]
        }

        Viewer --> Browsing : Tap Back, last item deleted, or asset vanished before/during delete
    }

    Gallery --> CheckingPermission : Photos access revoked in system Settings [foreground return]
```

## 5. Server user-to-user sharing state machine

API is shipped (`SharingEndpoints.cs`, `PostgresSharingRepository.cs`,
`PostgresGalleryRepository.cs`); native iOS sharing UI is planned.

```mermaid
stateDiagram-v2
    [*] --> NoShare

    NoShare --> ActiveShare : Owner PUT /v1/shares/id [enabled member + enabled discoverable recipient, subset or allAssets]
    ActiveShare --> ActiveShare : Owner PUT /v1/shares/id [updates subset or allAssets, bumps recipient share_generation]
    ActiveShare --> Revoked : Owner DELETE /v1/shares/id [bumps recipient share_generation]
    ActiveShare --> LeftByRecipient : Recipient DELETE /v1/shares/id [bumps recipient share_generation]

    Revoked --> [*]
    LeftByRecipient --> [*]

    note right of ActiveShare
        Recipient reads: valid snapshot serves shared items
        with SharedBy provenance. After share_generation bump,
        old snapshots return 410 Gone (new snapshot needed) or
        404 Not Found if no shares remain. Existing shares can
        still be updated even if recipient disables discoverability.
    end note
```

Native file sharing exports files through iOS Share Sheet and is independent of
server shares. Sharing media never shares the owner's private face labels.

## 6. Optional face analysis and person correction state machines

API and workers are shipped (`FaceEndpoints.cs`, `FaceWorker.cs`,
`PostgresFaceRepository.cs`); native People UI is planned.

### 6a. Face analysis job lifecycle

```mermaid
stateDiagram-v2
    [*] --> Queued : Library face_publications outbox OR owner POST /v1/faces/jobs/assetId [asset eligible and not in deleted_assets]

    Queued --> Running : FaceWorker claims job [attempts < 5, 3m lease]
    Running --> Running : Lease expired [attempts < 5, reclaimed]

    Running --> Complete : Inference succeeded with >= 1 face [observations + clusters + centroids committed]
    Running --> NoFaces : Inference succeeded with 0 faces
    Running --> Queued : Transient dependency error or 90s timeout [attempts < 5, quadratic backoff <= 300s]
    Running --> Error : Invalid media/provenance, attempts >= 5, or expired lease with attempts >= 5
    Running --> Denied : Library source check returned 404 [trashed, hidden, or owner disabled]

    Error --> Queued : Owner POST /jobs/id/retry [current pipeline_version, resets attempts=0]
    Denied --> Queued : Owner POST /jobs/id/retry OR re-enqueue after asset restore [resets attempts=0]

    Queued --> PurgedTombstone : Cleanup DELETE /internal/v1/faces/assets/assetId
    Running --> PurgedTombstone : Cleanup DELETE [running CompleteAsync fenced out]
    Complete --> PurgedTombstone : Cleanup DELETE [removes jobs, tracks, observations, recomputes centroids]
    NoFaces --> PurgedTombstone : Cleanup DELETE
    Error --> PurgedTombstone : Cleanup DELETE
    Denied --> PurgedTombstone : Cleanup DELETE

    Complete --> [*]
    NoFaces --> [*]
    PurgedTombstone --> [*]
```

### 6b. Owner person and track correction states

```mermaid
stateDiagram-v2
    [*] --> UnnamedPerson : New face cluster created [name=null, redirect_id=null]

    UnnamedPerson --> NamedPerson : PUT /people/id/name [sets name and aliases]
    NamedPerson --> NamedPerson : PUT /people/id/name [updates name/aliases]

    UnnamedPerson --> MergedRedirect : POST /people/id/merge [target root != source, depth < 32, no negative match]
    NamedPerson --> MergedRedirect : POST /people/id/merge [unnamed target inherits source name]
    MergedRedirect --> UnnamedPerson : DELETE /people/id/merge [undo redirect, original record survives]
    MergedRedirect --> NamedPerson : DELETE /people/id/merge [undo redirect, original name survives]

    NamedPerson --> NegativeConstrained : POST /people/id/negative-matches [blocks conflicting future merges]
    UnnamedPerson --> NegativeConstrained : POST /people/id/negative-matches
    NegativeConstrained --> NamedPerson : DELETE /people/id/negative-matches/otherId [audit history retained]
    NegativeConstrained --> UnnamedPerson : DELETE /people/id/negative-matches/otherId

    note right of MergedRedirect
        Per-track corrections (PUT /observations/id/person)
        Generated to ManualAssigned / SplitNewPerson / ManualUnknown.
        Manual assignment resolves redirected person IDs to their
        active root and records prior generated/manual exclusions.
    end note
```

Merging people changes cluster redirects; it does not train the model.

## 7. Server deletion, trash retention and physical cleanup state machine

Models `PostgresAssetRepository.DeleteAsync`, `PostgresTrashRepository.cs`,
`CleanupJob.cs`, and `BlobCleanupRepository.cs`. The current iOS app only
exposes local Photos deletion, not server deletion or trash/restore UI.

```mermaid
stateDiagram-v2
    [*] --> Active : Committed asset or resource set

    Active --> Trashed : Owner DELETE /v1/assets/id [marks whole group deleted_at=now, cancels face_publications, hides from gallery/shares]
    Trashed --> Active : Owner POST /v1/assets/id/restore [within 30d and purge_started_at IS NULL, resets face_publications]

    Trashed --> ExpiredPendingCleanup : 30 days elapsed [still listed in /v1/trash until claimed, restore returns 409 Expired]
    ExpiredPendingCleanup --> PurgeClaimed : CleanupJob POST /cleanup/claim [sets purge_started_at, 10m lease, hidden from /v1/trash]

    PurgeClaimed --> PurgeClaimed : Downstream failure or lease expiry [reclaimed after 10m, restore stays 409]
    PurgeClaimed --> Purged : Storage ref released + Faces/hooks deleted + POST /cleanup/id/complete [purged_at=now]

    Purged --> BlobRetained : Other blob_references, active upload, retention hold, or unsent outbox exists
    BlobRetained --> BlobRetained : Cleanup GC skips blob until all blockers clear
    BlobRetained --> BlobDeletingFence : All blockers clear [sets blobs.deleting=true under per-hash lock]
    Purged --> BlobDeletingFence : No remaining references, holds, active uploads, or unsent outbox
    BlobDeletingFence --> BlobRemoved : Unlinks original + previews, deletes blobs row, optional history compaction

    BlobRemoved --> [*]
```

## 8. Private device revocation state machine

Models `scripts/admin_web.py` (`revoke_device`), `device-revoke.html`, and
`NephosAdminResource.java` (`revokeDevice`).

```mermaid
stateDiagram-v2
    [*] --> ViewingDevices : Administrator opens user page [GET /users/subject]

    ViewingDevices --> Confirming : Click Revoke on selected device [GET /revoke finds active session]
    ViewingDevices --> NotFound404 : GET /revoke [device already disconnected]

    Confirming --> ViewingDevices : Click Cancel or close modal
    Confirming --> Submitting : Submit POST /revoke [CSRF valid]

    Submitting --> ConfirmedRevoked : Keycloak DELETE 204 [session removed + invite status=revoked]
    Submitting --> AlreadyDisconnected : Pre-check sees gone OR DELETE returns concurrent 404
    Submitting --> UnconfirmedError : Pre-check or DELETE fails with 5xx/network/timeout [renders 503 modal]

    UnconfirmedError --> ViewingDevices : Click Check devices to reconcile
    UnconfirmedError --> Submitting : Click Retry revoke

    ConfirmedRevoked --> ViewingDevices : Flash confirmation [other sessions and media untouched]
    AlreadyDisconnected --> ViewingDevices : Flash already disconnected
    NotFound404 --> [*]
```

After `ConfirmedRevoked`, the revoked device returns to sign-in on its next
protected API validation or upload authorization check; other sessions and
stored media remain intact.

