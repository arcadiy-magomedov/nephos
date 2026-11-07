# Private administration API

The administrator console talks to Library at `/internal/v1/admin` using
`X-Nephos-Service-Key` (`Administration:Key`), never through the public gateway.
Legacy `/internal/admin` aliases and `/state`, `/principals`, `/libraries`
contracts remain available for rolling upgrades.
The legacy state snapshot remains bounded to 1000 rows per collection and
explicitly reports principalTotal, libraryTotal and truncated; new consumers
must use the paginated collection routes.

Administration requires the existing separate `LibraryAdmin` owner connection.
The normal `library_app` role cannot provision principals, modify membership,
or write operations/audit records. Additive Library migrations preserve
memberships, shares, uploader rights, media and existing account email.
Historical ownership is backfilled only when unambiguous; unknown ownership
remains visible instead of granting a guessed owner new rights.

## Read contracts

- `GET /users?search=&enabled=&cursor=&limit=` returns
  `{items,nextCursor,total}`. Users expose subject, immutable login, displayName,
  enabled, discoverable, revision, identityRevision, personalLibraryId and
  provisioningStatus. User detail `/users/{subject}` returns
  `{user,libraries,memberships}`.
- `GET /libraries?search=&cursor=&limit=` returns the same page envelope.
  Libraries include actual owner, revision, direct member count and retained
  asset count/bytes. Detail `/libraries/{id}` returns `{library,members}`.
  Member scope is `member` or `share`; direct members can upload and share their
  own uploaded media. Scoped recipients cannot upload/share. Existing multiple
  libraries and direct/scoped memberships remain independent.
- `GET /operations?status=&cursor=&limit=` and `/operations/{id}` expose durable
  provisioning/profile/access progress, sanitized failures and original
  operator attribution. Never report success before `status=completed`.

All pages are server-filtered with matching totals, bounded to 1–100 items and
stable identity cursors. Search is literal, case-insensitive, at most 200
characters. JSON uses camelCase.

## Command contracts

New user commands require `X-Nephos-Operator-Subject`, a real Keycloak UUID
derived by the authenticated console from operator userinfo, not browser input.

- `POST /operations`: `{id,login,displayName,discoverable,libraryName}`.
  The command UUID and normalized request are bound to the original operator.
  Login is lowercase `[a-z0-9][a-z0-9._-]{0,63}`; names are required, at most
  200 characters, with no controls.
- `POST /users/{subject}/profile`:
  `{commandId,expectedRevision,displayName,discoverable}`.
  Display/directory changes never change access or immutable login.
- `POST /users/{subject}/access`:
  `{commandId,expectedRevision,enabled}`.
  Disable immediately fences Library access. Enable occurs only after provider
  success; provider disable revokes all existing sessions/invitations.
- These commands return 202 with an operation. Same command/request/operator
  replays return the same operation; conflicting requests return 409.
- `POST /operations/{id}/retry` resumes the retained step. Transient failures
  retry automatically; explicit operator retries of provider revision conflicts
  reconcile the current provider fence before reapplying the retained intent.
  The retry actor is recorded separately in append-only administration events.
- `POST /operations/{id}/abandon` terminates only failed profile/access
  operations as `abandoned`, allowing a corrected new command with the current
  user revision. It never abandons in-flight/provisioning operations or clears
  local access denial. Abandoned commands cannot be retried.
- `POST /libraries`: `{id,name,subject}` binds the initial library name and owner
  to the ID. Replay after rename does not revert the current name.
- `POST /libraries/{id}/rename`: `{name,expectedRevision}`.
- `POST /libraries/{id}/owner`: `{subject,expectedRevision,personal:false}`.
  Initial assignment only, to an existing direct member. No ownership transfer,
  member grants or personal-library replacement is permitted.

## Reconciliation and identity projection

Configure the private Library admin process with:

```
Administration__Enabled=true
Administration__IdentityUrl=http://keycloak:8080/realms/nephos/nephos-admin
Administration__IdentityKey=<existing identity service key>
```

The .NET reconciler durably reserves case-insensitive login, predetermined
identity and personal library IDs. It creates a disabled Keycloak identity,
atomically persists personal library/membership, enables Keycloak, and finally
completes/enables Library. Database leases recover on restart and prevent
duplicate work across processes. Lost responses replay the same provider
command. No compensating deletion of pre-existing accounts is performed.
Explicit re-enable first durably disables/revokes provider sessions, then
enables. Persistent local denial survives failed/abandoned disable operations
and identity synchronization, preventing premature access or resurrection of
sessions from a disable that had not completed.

A separate .NET worker bootstraps and refreshes actual human Keycloak identities
every 30 seconds via private paginated `GET /users`; service accounts are
excluded. `POST /identities` also accepts bounded real projections
`{items:[{subject,login,displayName,enabled,revision}]}`. Stale provider revisions
and updates during unfinished operations cannot overwrite local denial/profile
intent. Directory settings, email, memberships and shares are preserved.
Provider outages retain last-known projections rather than fabricating users.

## Private summaries

Library, Storage and Faces each expose `/internal/v1/admin/summary` protected by
their configured `Administration:Key`. Capacity/byte/count fields are integers;
ages are seconds; checkedAt is an ISO timestamp. Database/filesystem failure is
503, never a synthetic zero/healthy response.

- Library: userCount, enabledUserCount, libraryCount, assetCount, sizeBytes,
  operationsPending, operationsFailed, publicationPending, identitySyncedAt.
  Asset counts include retained trash and exclude purged assets.
- Storage: capacityBytes, freeBytes, usedBytes, blobCount, blobBytes, uploading,
  verifying, failedLastDay, verificationAgeSeconds, outboxPending. Capacity is
  the actual mounted filesystem; blob bytes represent deduplicated originals,
  not previews or the whole filesystem.
- Faces: queued, running, complete, noFaces, error, denied, activeLeases,
  oldestPendingAgeSeconds. Active leases are jobs, not invented worker counts.

Readiness is `/health/ready`; liveness is `/health/live`.
No secrets, filesystem paths or arbitrary probe configuration are returned.
