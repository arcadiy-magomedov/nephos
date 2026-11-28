# Implementation and media API

## Current scope

Nephos implements known-user authentication, private administration, resumable
original-file uploads, compound resource sets, authorized gallery APIs, sharing,
retention, cleanup and optional owner-private face analysis.

The iOS app supports QR enrollment, persistent sessions, local Photos/Live Photo
browsing and sharing, and optional automatic backup. Remote gallery browsing,
People, Search and server-sharing management are not yet implemented in the app.
Books/cinema applications, semantic search, APNs, Android, Helm and multi-host HA
remain roadmap items. The platform is not production-qualified as a whole.

See [system and UX diagrams](system-and-flows.md), the
[iOS implementation](ios-client.md), [face analysis](face-analysis.md) and
[API versioning rules](005-api-compatibility.md).

## Authentication and ownership

Media, library and upload routes require a valid Keycloak token with audience
`nephos-api` and enabled platform membership. Provider-account existence alone
does not grant access. APIs check live session state; authentication dependency
failures are retryable errors, not proof of revocation.

Originals are content-addressed, but access belongs to logical library/upload
references. Same-owner/library duplicates may short-circuit. Knowledge of
another user's file hash does not grant access or bypass uploading bytes.
Sharing is read-only, owner-controlled and limited to known users; recipients can
identify shared provenance. Private face labels are not shared with media.

## Public routes

| Method and path | Contract |
|---|---|
| `GET /v1/config` | Public server identity and versioned client configuration |
| `GET /v1/libraries` | Membership-scoped library pages |
| `POST /v1/uploads` | Upload intent: ID, library, filename, MIME type, size, optional hash/capture time/resource-set ID |
| `GET /v1/uploads/{id}` | State, received parts, chunk size, error and committed asset ID |
| `PUT /v1/uploads/{id}/parts/{index}` | Exact immutable chunk bytes; identical retries are idempotent |
| `POST /v1/uploads/{id}/complete` | Seal a complete part set; asynchronous verification |
| `POST /v1/uploads/{id}/retry` | Retry an authorized failed upload |
| `DELETE /v1/uploads/{id}` | Cancel before sealing; never delete a committed original |
| `PUT /v1/libraries/{id}/resource-sets/{setId}` | Immutable complete compound-resource manifest |
| `GET /v1/resource-sets/{id}` | Authorized complete resource manifest |
| `GET /v1/assets/{id}/resources` | Manifest containing the asset |
| `GET /v1/libraries/{id}/assets` | Gallery page with capture/upload chronology |
| `GET /v1/libraries/{id}/timeline` | UTC year/month/day counts |
| `POST /v1/libraries/{id}/snapshots` | Frozen revision, access generation, expiry and counts |
| `GET /v1/libraries/{id}/snapshots/{snapshot}/assets` | Frozen gallery page |
| `GET /v1/libraries/{id}/snapshots/{snapshot}/timeline` | Frozen timeline |
| `GET /v1/libraries/{id}/changes` | Bounded whole-revision change batches |
| `GET /v1/assets/{id}/original` | Exact authorized original with Range/HEAD support |
| `GET /v1/assets/{id}/preview?size=512` | Authorized JPEG preview; sizes 512, 1280 or 2560 |
| `GET /v1/assets/{id}/backup` | Fresh committed-reference/file availability evidence |
| `POST /v1/assets/{id}/retention` | Owner-only rehash and renewable retention hold |
| `POST /v1/resource-sets/{id}/retention` | Fresh retention evidence for every resource |
| `DELETE /v1/assets/{id}` | Owner-only logical deletion of the complete resource |
| `GET /v1/trash` | Owner-only retained deleted assets |
| `GET /v1/trash/{id}/preview` | Owner-only retained preview |
| `POST /v1/assets/{id}/restore` | Restore an eligible deleted resource without recreating a Photos copy |

Sharing routes are specified in [system architecture](001-system-architecture.md)
and implemented in `src/Nephos.Library.Api/Sharing/`. Face routes are documented
in [face analysis](face-analysis.md); administrative routes in
[the administration API](administration-api.md).

## Upload and publication

The media API uses immutable 4 MiB chunks, sent in any order. Limits are 8 GiB
per file, 16 pending uploads per user and 64 GiB pending reservations globally.
Idle uploads expire after 24 hours. The server verifies exact length and SHA-256
before publishing a durable reference and transactional outbox event.

Workers publish through RabbitMQ with confirms and manual acknowledgements.
Library projection is idempotent. A chunk receipt or HTTP 202 is not backup
completion: `ready` requires both verified storage and committed projection.
An authorized duplicate can return a previous upload ID; use the returned ID.

Compound manifests contain 1-16 distinct owned, committed resources and preserve
original roles, hashes, sizes, filenames and uniform type identifiers.
Kinds include single, Live Photo, RAW/JPEG, edited and archive resources.
Constituents remain hidden until the complete manifest is committed. A Live Photo
is one batch item, not one item per constituent file.

## Gallery and previews

Gallery cursors pair `before=<createdAt>` with `beforeId=<id>`. Library/gallery
page sizes are 1-100. Immutable snapshots retain ordering and counts for seven
days, with up to 20,000 active views per user/library. Access-generation fencing
prevents stale views from surviving revoked membership or sharing.

Catch-up applies all revision batches through a retained target atomically.
HTTP 410 requires a fresh snapshot; unavailable membership returns 404.
History compaction retains versions and tombstones needed by active snapshots.

Originals are never transcoded. The private renderer generates fixed JPEG
variants, sharded by content hash; unsupported previews do not discard originals.
Video/GIF previews use bounded FFmpeg decoding. Preview responses use
`Cache-Control: private, no-cache` and ETag revalidation so access revocation is
checked even for cached content.

## Deletion and phone cleanup

Server deletion immediately hides resources from ordinary/shared views and starts
a 30-day recovery period. Restore preserves IDs, originals, manifests and retained
analysis. Cleanup releases individual references after expiry; physical GC waits
for other references, holds and in-flight publication. See [cleanup](cleanup.md).

Phone removal requires the complete unchanged local source revision, exact
hash/size, fresh retention assurance and Photos confirmation. Unsupported
compound/edited resources remain ineligible. Server and OS operations are not an
atomic transaction. The current native viewer offers local Photos deletion,
not server deletion or Delete everywhere.

The server reports `single-volume-no-independent-backup`. References and holds
protect against application release, not disk loss, ransomware or operator
deletion. Photos deletion may propagate through iCloud; it is not cache eviction.
