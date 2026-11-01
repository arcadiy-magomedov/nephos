# Nephos native iOS

Native SwiftUI/UIKit application, iOS 17+, using PhotoKit, Security/Keychain,
CryptoKit, URLSession, AVKit and BackgroundTasks. No external
packages. The checked-in Xcode project is generated deterministically by
`python3 generate_project.py`; generation is only needed after adding source files.
Core invariants also form a dependency-free Swift package.

## SwiftUI responsiveness and lifecycle

Gallery merging, indexed upload/local matching, filtering, date parsing and day
grouping produce a cached, cancellable snapshot off MainActor. Scroll targets use
the same stable string IDs as the grid. PhotoKit gallery enumeration and ImageIO
preview decoding/cropping also run outside the UI actor; decoded previews retain
the account/cache-generation fence before publication. Local thumbnails use
layout pixel dimensions and local viewers request bounded screen-sized images,
not full-resolution originals.

Both PhotoKit image/video requests and awaited background uploads bridge Swift
task cancellation to the underlying request. Carousel pages load only while
selected; late responses and errors cannot update another account or restart
offscreen playback. Local viewer failures expose retry rather than an indefinite
spinner. Source badges use scalable semantic fonts, gallery/trash grids reduce
their columns at accessibility text sizes, selected items expose VoiceOver state,
and image zoom has adjustable and reset accessibility actions. The accent color
supports Increase Contrast in light and dark appearances.

Ledger and gallery disk operations are serialized outside MainActor. Critical
backup/deletion writes are awaited before proceeding; scroll-anchor writes are
coalesced and flushed when the scene backgrounds. Automatic backup responds to
Photos, connection, foreground, retry deadlines and system background tasks,
without a separate once-per-minute polling loop.

These invariants have regression coverage, but do not constitute a measured
frame-rate guarantee. Profile representative large libraries on a physical
iPhone using Apple's SwiftUI/Time Profiler Instruments and audit Dynamic Type
and VoiceOver with Accessibility Inspector before claiming performance budgets.

## Native design and social journeys

The [approved first-launch wizard](../design/ios/onboarding.html) is now native
SwiftUI. Server/issuer preflight, explicit trust, email/PIN sign-in, library
selection, optional Photos access and a final confirmation are separate steps.
Unreachable API/identity endpoints and untrusted certificates have inline recovery
guidance; a remote server advertising a loopback issuer is rejected before login.
The issuer is displayed explicitly even when it differs from the API origin.
TLS validation and OIDC issuer/nonce checks remain mandatory. The native client
first validates an email against enabled known accounts, then requests a
one-time 8-digit PIN. Only the private admin console displays the generated PIN
for manual delivery; the unauthenticated requester never receives it. A separate
PIN-entry screen exchanges it for standard Keycloak OIDC access, identity, and
offline refresh tokens. PINs expire after 30 minutes;
reissuing one replaces its predecessor. The public client does not use a client
secret or receive a password. Initial ID tokens require the generated nonce.
Refresh ID tokens may omit it (OIDC Core 12.2), but cannot change it or the
account subject. Signature, issuer, audience and lifetime validation still
apply before refreshed credentials are saved. Offline refresh sessions survive
idle time and are revoked by disabling the account or revoking that device in
the admin console. Associated Domains and passkeys are not part of this login
flow.

**Find nearby servers** starts an optional Bonjour search on the first step.
The host advertises `_nephos._tcp` with a versioned TXT record containing its
canonical HTTPS URL; see [host setup](../deploy/discovery/README.md).
Results never overwrite a manually entered address until selected. Selection
performs normal preflight and still requires explicit trust. No passkey, token
or certificate is accepted from discovery. Both app configurations declare
Bonjour/Local Network usage; discovery stops when leaving the server step or
backgrounding the app. Manual URLs remain available if discovery is denied,
blocked by the network or unsupported by the server.

The validated server-address draft survives restart even if TLS or discovery
fails. Change server signs out and removes the old approved connection, without
deleting account upload ledgers or staged originals. A saved remote server with a
localhost issuer cannot resume directly into sign-in. Every replacement requires
a successful preflight and explicit approval; failed checks never reuse a previous
proposal. Authenticated setup choices are
saved in the account-isolated ledger; interrupted setup resumes without enabling
backup. Completing browse-only setup does not request Photos access. Shared
libraries cannot be upload targets; denied/limited Photos access is handled
without enabling cleanup. Automatic backup stays gated until setup is complete.
Existing accounts with a selected library or queued resources keep their setup
and are not forced through the new-account wizard after an update.

For local HTTPS, install the operator-provided CA on the iPhone and separately
enable full trust in Settings > General > About > Certificate Trust Settings.
Use the certificate's hostname, not an arbitrary IP address. App signing trust
and HTTPS certificate trust are separate. Account creation remains an
administrator operation; installing the app does not create a Nephos account.

The approved [design board](../design/ios/screens.html) is implemented using
native SwiftUI controls (including the host iOS version's navigation/tab-bar
appearance), not a web view. There are no decorative subtitles above page titles.
Existing English UI copy is retained; this is not a complete Russian localization.

- Photos: three-column chronological previews (two at accessibility text sizes), loaded-window photo/video/shared
  filters, visible shared provenance, selection, date navigation and refresh.
  Backup and Settings are reached from the gallery rather than occupying tabs.
- Appearance: `@AppStorage` plus `preferredColorScheme`, System by default,
  explicit Light/Dark overrides persisted on this installation, including sheets
  and the signed-out appearance settings. Both modes share the same layout.
- People: real authorized face crops, case-insensitive name/alias substring search, person photos,
  name/alias edits, confirmed merges, current-merge undo, individual-face
  reassignment/split, different-person rules and removal through history.
- Sharing: known-user directory, selected originals or all/future media with
  explicit confirmation, editable selection/scope, incoming read-only media and
  outgoing grant revocation. Originals already downloaded cannot be revoked.
- Viewer: sized previews on a black canvas, pinch/double-tap and VoiceOver zoom, people
  inspection, explicit original export/restore and retention details.
- Backup: two-column local photo previews, circular per-photo upload progress,
  compact saved/remaining photo counts and persistent pause/resume. Live Photos
  and edited originals occupy one tile, not a separate row per sidecar.
  Percentages count acknowledged bytes; preparation and final publication show
  an indeterminate indicator. A checkmark requires the complete verified backup.
  Counts describe the queued ledger, not an invented total of all Photos items.
  The newest 100 tiles prioritize unfinished items. Thumbnails do not initiate
  iCloud downloads; inaccessible local previews have a placeholder.
  **+** opens Photos selection; **...** contains backup settings and **Back up now**.
  Tap a photo for its status, recovery and **Retry this item**, which does not
  bypass another item's backoff. Raw errors, identifiers and transfer details
  stay collapsed under **Technical details**. Pause does not interrupt
  already-running Photos preparation or server-side verification.

The queue runs up to three independent uploads concurrently, including manual
selection, automatic discovery and resumed queues. PhotoKit preparation remains
serialized; storage budgeting reserves space for all active chunk files and their
atomic writes. A compound item's manifest is published only after every file is
verified. Opaque PhotoKit resources (`unknown-<positive type>`, including Apple's
adjustment envelope) and `photoProxy` are retained byte-for-byte, not discarded or
misrepresented as natively restorable. Edited/unsupported items remain ineligible
for automatic phone cleanup.
On upgrade, previously rejected opaque-resource manifests are retried once when
every constituent already has matching verification evidence. This reuses the
existing uploads; incomplete sets, denied access and newly rejected attempts stay
blocked rather than entering a retry loop.

Gallery query encoding preserves literal plus signs, including positive UTC
offsets in saved pagination anchors. A retained gallery is labelled as a saved
copy rather than implying that every refresh failure is an authentication error.
The visible, active gallery checks for changes on opening, foreground return and
reconnection, then every 15 seconds. This is independent of automatic backup,
pause and read-only sharing. Unchanged revisions avoid refetching asset pages.
New photos appear at the newest view; older browsing retains its anchor and
loaded window, bounded to 300 items. Automatic refresh does not issue a command
to align the visible photo to the viewport top.
Explicit navigation/restoration scroll requests are consumed once, not replayed
whenever upload-state changes rebuild the unified gallery.
Publishing a phone original keeps its local cell ID, capture date and day group;
the server reference changes its backup state without relocating the thumbnail.
Preview refreshes retain the displayed image while its replacement loads; account,
library and source changes still clear it. Core regressions cover both continuity
and clearing at those privacy boundaries.
The mandatory native suite also compares thumbnail pixels during a delayed refresh
and local-to-server publication, and checks that rename/merge refresh the People list.
People mutations invalidate cached lists, and stale detail requests cannot apply names.
Merges keep a named destination, or inherit the source name when it is unnamed.
Source names and aliases remain searchable through the destination; undo restores
the separate groups without discarding either label.
Historical/date windows remain historical.
Failures keep cached metadata and use inline recovery with polling backoff up to
five minutes, not repeated alerts. Media still requires current authorization.

Temporary network failures, HTTP 408/425/429 and server 5xx responses retry with
persisted exponential backoff: 30 seconds, 1/2/4 minutes, up to one hour.
A cancellable deadline wakes the foreground queue even with automatic Photos
discovery disabled, and drains remaining bounded batches. Manual **Back up now**
bypasses backoff. Pause, sign-out, account/library changes, read-only access and
network policy still gate work. Certificate, authorization and invalid-data
failures do not automatically retry; their durable records remain available for
review and manual retry. Reconciliation preserves already-acknowledged parts.
PhotoKit network-required (3164), network-error (3169) and interrupted-operation
(3301) failures also retry. An upgrade reopens previously blocked items with
these errors without replacing their originals or acknowledged parts.
Already-verified photo manifests can finish publishing over a connected network
even when Wi-Fi-only or Low Data Mode blocks media transfer. These metadata
requests do not enable cellular original downloads. Original transfer continues
to respect the explicit cellular preference and Low Data Mode.
This foreground timer is not an iOS background execution entitlement:
background URLSession transfers and BGProcessing opportunities remain OS-controlled;
continuous whole-queue progress while suspended has not been qualified on-device.

People/sharing pages are bounded to 300 retained rows with explicit pagination
and errors. Requests are fenced by account/library generation. No test login,
fixture token or demo-media mode is compiled into the production app.

### Native social acceptance and UI qualification

After preparing the licensed face fixtures and starting a stable local Faces
deployment, run:

```sh
python3 run_social_e2e.py --backend-stable
# Also render production SwiftUI views in a separate test application:
python3 run_social_e2e.py --backend-stable --simulator <booted-simulator-UUID>
```

The runner uploads two attributed portrait fixtures through real verification,
waits for actual face inference, and exercises the production Swift APIs for
private names, merge/undo, split/reassignment, negative matches, directory,
selected/all grants, narrowing and original/preview revocation.
Known-user accounts, grants, media and face rows are disposable and cleaned.
The UI host has a separate bundle ID, receives fixture credentials only through
its process environment, and is uninstalled after capture. Its initializer is
behind `UI_QUALIFICATION`, which is absent from Debug/Release app builds.
Screenshots under `.logs/design-ui/` are **native views using real fixture API
data**, not proof of user-driven passkey login or physical-device acceptance.

The local design acceptance covers deterministic core tests, real native social
API integration, and Debug/Release simulator compilation. The existing original
upload/restore acceptance and physical-device boundaries below still apply.
Wizard qualification additionally exercised real OIDC preflight and persisted
browse-only completion, rendered all six native steps, and built signed
Debug/Release device binaries. Development updates are installed in place,
without uninstalling the app. This is not a claim that a human
passkey login, background Photos upload or deletion has been accepted on-device.

For interactive regression through the actual production onboarding controls,
use an isolated XCTest application (not the installed production bundle):

```sh
python3 onboarding_qualification.py --simulator <booted-simulator-UUID> \
  --base-url https://server-hostname:port \
  --certificate-error-url https://address-not-covered-by-certificate:port \
  --signin-email enabled-fixture@example.test
```

Add `--complete-signin` for a disposable account provisioned through the private
admin console: the driver obtains its PIN privately, enters it in the native UI,
and requires the writable-library setup screen. Temporary test configuration is
removed afterward. Never use this option with a personal or production account.

The simulator must trust the development CA. The test seeds an old IP/localhost
connection, drives failed TLS checks, draft persistence, server replacement,
approval/relaunch, email validation, unknown-account rejection, the separate
PIN-entry screen and changing email. Use an enabled disposable fixture account;
its generated PIN is visible only in the private admin console. The test does not
simulate Face ID or silently trust certificates. The disposable app and its
generated Xcode project are removed afterward; personal signing settings are
untouched.
Add `--discovery` while a real host advertisement is running to also exercise
the native nearby-server list, stopping/restarting search, URL selection and
the explicit-trust boundary. The qualification does not inject fake discovery
results; it browses the real local DNS-SD service.

## Build and verification

Run from `ios/`:

```sh
swift test --scratch-path .build

# With the local development administration stack and Playwright installed:
# a disposable operator fixture exercises real OIDC refresh; only verified claim
# fields (never bearer/refresh tokens) reach the production Swift claim validator.
python3 run_identity_refresh_e2e.py

# Actual BackupView/AppModel: controlled 503, automatic retry, collapsed errors,
# pause past the deadline, and resume. Separate simulator app; no user media.
python3 onboarding_qualification.py --backup --simulator <booted-simulator-UUID>

# Signing-disabled simulator build; no developer team is needed.
# Direct-target builds are independent of the selected Xcode destination.
xcodebuild -project Nephos.xcodeproj -target Nephos \
  -configuration Debug -sdk iphonesimulator \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO \
  CONFIGURATION_BUILD_DIR="$PWD/.derivedData/Build/Products/Debug-iphonesimulator" \
  OBJROOT="$PWD/.derivedData/Build/Intermediates.noindex" \
  SYMROOT="$PWD/.derivedData/Build/Products" build

xcodebuild -project Nephos.xcodeproj -target Nephos \
  -configuration Release -sdk iphonesimulator \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO \
  CONFIGURATION_BUILD_DIR="$PWD/.derivedData/Build/Products/Release-iphonesimulator" \
  OBJROOT="$PWD/.derivedData/Build/Intermediates.noindex" \
  SYMROOT="$PWD/.derivedData/Build/Products" build
```

For an **installable simulator run**, use Xcode's ad-hoc simulator signing
(no developer team/certificate is needed):

```sh
xcodebuild -project Nephos.xcodeproj -target Nephos \
  -configuration Debug -sdk iphonesimulator \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
  CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES CODE_SIGN_IDENTITY=- \
  CONFIGURATION_BUILD_DIR="$PWD/.derivedData/Build/Products/Debug-iphonesimulator" \
  OBJROOT="$PWD/.derivedData/Build/Intermediates.noindex" \
  SYMROOT="$PWD/.derivedData/Build/Products" build
```

The signing-disabled commands above prove compilation, but omit Xcode's
simulated application-identifier entitlement and can make Keychain operations
fail at launch. The signed-simulator command was verified to launch the setup
screen without a local-state/Keychain error. Do not solve this by bypassing
Keychain or putting credentials in preferences. Device signing remains separate.

Actual local verification, 2026-10-30:

- Xcode 26.5 / Swift compiler 6.3.2: Debug and Release simulator builds pass.
  App language mode is Swift 5; the standalone core package uses Swift 6.
- Deterministic XCTest suite: **20 tests pass** (SHA-256 streamed-file vectors,
  RFC 7636 PKCE vector, exact chunk coverage, capture-date intent serialization,
  account isolation, atomic ledger persistence/corruption, independent settings,
  bounded retry, canonical dedup IDs, server-status reconciliation, paged
  chronology, atomic delta-page validation, timestamp-tie anchors, UTC date jumps,
  isolated retained-window persistence, legacy schema compatibility, complete
  resource-set publication gates, complete retention, restore-role allowlists,
  bounded HTTP range validation and unchanged cleanup gates).
- Installed and launched on the available iPhone 17 Pro Max / iOS 26.2 simulator:

  ```sh
  xcrun simctl boot 9A666819-F177-4883-870B-267D1D87F70A
  xcrun simctl bootstatus 9A666819-F177-4883-870B-267D1D87F70A -b
  xcrun simctl install 9A666819-F177-4883-870B-267D1D87F70A \
    .derivedData/Build/Products/Debug-iphonesimulator/Nephos.app
  xcrun simctl launch 9A666819-F177-4883-870B-267D1D87F70A app.nephos.ios
  ```

- Visually checked the final installed setup screen: no Photos
  prompt appears on startup. Photos observer registration waits for permission.
- Release Info.plist has **no ATS exceptions**. DEBUG HTTP opt-in is absent
  from the Release UI and rejected by Release URL validation.
- This machine's `xcodebuild -scheme Nephos -destination
  'generic/platform=iOS Simulator'` reports “iOS 26.5 is not installed”.
  Installed runtime is 26.2, while the compiler SDK is 26.5. Building the target
  directly works; this is not a Swift compilation blocker. On a fully installed
  Xcode, the shared `Nephos` scheme is available for normal Run/build operations.
- Build logs and a setup screenshot are local ignored artifacts in `.logs/`.
  The only build warning is unused AppIntents metadata extraction.

Build/simulator checks alone do not establish authenticated integration.
The native Swift fixture-backed integration result below is separate evidence.
Neither establishes physical-device passkey/Photos/background-transfer/removal
behavior, production signing, or App Store readiness.

**Preview update, 2026-10-31:** the native HTTP integration passed in 14.658 seconds,
including all three authenticated preview sizes and byte-exact explicit original
export. The 21 deterministic tests and Debug/Release simulator builds pass; the
ad-hoc signed app was installed and launched on the existing simulator. This is
not a claim of UI-driven authenticated or physical-device acceptance.

### Opt-in native Swift backend XCTest

`NativeBackendTests` compiles alongside the deterministic tests but skips unless
explicitly enabled. It uses the **same production Swift `HTTP`, `API`,
`UploadClient`, hashing, chunking and ledger implementations as the iOS app**.
The host is native macOS XCTest via SwiftPM, not a browser, Python HTTP
reimplementation, UI automation or passkey simulation. Production iOS continues
to supply tokens only through its validated `AuthSession`; the fixture token
provider and environment lookup exist only in the test target.

Wait until the operator says the disposable backend is stable, then run:

```sh
cd ios
python3 run_native_e2e.py --backend-stable
```

The runner imports `scripts/media-smoke.py` with `runpy`, uses its `account()`
context manager to obtain a real signed fixture token and isolated library,
and pre-registers the intended upload UUID in the fixture's cleanup list.
Bearer credentials travel only in the child process environment, never command
arguments, source files or logs; unexpected test output is defensively redacted.
The shared fixture removes the account, SQL rows, retained asset and media even
after test failure. Scratch data lives under `ios/.test-work/` and is removed.
No service is restarted or stopped by this native runner.

The XCTest covers configuration, authorized libraries, a deterministic
two-full-chunk-plus-short-tail original, stable repeated upload intent,
out-of-order/identical repeated part, disk-ledger/client reconstruction and
server-part reconciliation, verification polling, capture-date gallery,
byte-for-byte and SHA-256 original equality, backup evidence, and a real
retention hold. It additionally uploads two synthetic two-resource sets,
checks hidden constituents before publication, immutable repeated publication,
same-owner same-byte dedup with distinct logical resource IDs, complete manifests,
all-original retrieval and all-resource holds. Retained snapshots remain frozen
across later uploads; year/day counts, date jumps, authenticated byte ranges,
delta catch-up through a fixed target, and durable snapshot restoration are
exercised by the production Swift client. The runner requires the current retention endpoint; direct
test-only environments may omit `NEPHOS_E2E_REQUIRE_RETENTION=1` to tolerate
an older profile's retention 404. Unsupported synthetic sources still fail
the cleanup gate; this test never invokes Photos deletion.

**Actual network evidence — PASS, 2026-10-30:** after the operator confirmed
backend stability, `python3 run_native_e2e.py --backend-stable` ran against
`http://localhost:18080`. The final expanded native XCTest passed in **12.437 seconds**, with
zero failures. Its **8,388,625-byte** original completed the real upload,
verification and gallery-publication path; the downloaded bytes and SHA-256
matched exactly, capture-date chronology matched, and the retention hold passed
identity/hash/size/availability/assurance/expiry checks. The fixture's registered
upload IDs (one legacy plus four compound constituents), account, SQL state,
retained media and local scratch files were cleaned
up. No backend services were stopped or restarted by this test.

This is **native macOS XCTest executing production Swift HTTP/upload code with
real signed fixture tokens**, using foreground URLSession file transfers.
It is not physical-device OIDC/passkey login, PhotoKit export/removal, iOS
background transfer scheduling, or UI-driven end-to-end evidence. Ordinary
`swift test` reports 20 deterministic passes and one intentionally
skipped opt-in network test. The final run occurred after the operator's updated
backend stability confirmation; no shared service was restarted by native tests.
The local redacted run log is `.logs/native-e2e-new.log`. Final unsigned build
logs are `.logs/debug-new.log` and `.logs/release-new.log`; the successful
ad-hoc simulator install build is `.logs/debug-simulator-signed.log`, and
`.logs/native-final-setup.png` records the clean launch UI.

### Simulator restoration qualification

`Qualification/PhotosQualification.swift` is a **separate simulator executable**,
not part of the production app. It generates an original JPEG and a QuickTime
movie with matching Live Photo content identifier/still-image-time metadata.
When full Photos permission is available, it calls the production restore path
for single photo, single video, and Live Photo; re-exports every created
PhotoKit resource; checks exact SHA-256/size, Live Photo subtype, and cleanup
eligibility. It never uses a backend token or invokes the application's cleanup
flow. It reports created synthetic identifiers, and does not erase existing Photos.

```sh
python3 run_photos_qualification.py --simulator <already-booted-simulator-UUID>
```

**Actual retry on 2026-10-30: PASS**, on the existing iPhone 17 Pro Max /
iOS 26.2 simulator, built with Xcode 26.5. Single JPEG, single QuickTime video,
and an unedited Live Photo were created through the production restore path
and re-exported through PhotoKit. Every original's SHA-256 and size matched.
The Live Photo retained its paired subtype/resources; cleanup eligibility
remained enabled only for the supported singles, not the compound item.

The initial probe incorrectly stopped at `notDetermined` after a successful
`simctl privacy ... grant photos`. Calling the production `requestAccess()`
path before checking authorization resolved that blocker. The runner now allows
up to 120 seconds for genuine Photos consent and processing; denied/limited
permission still fails the full-library qualification.

The successful run removed its helper app/build scratch and left three clearly
named synthetic Photos fixtures for inspection. Existing Photos and the
workspace simulator were not erased. Evidence and fixture identifiers are in
`.logs/photos-qualification.json`.

Use `--use-existing-permission` to preserve permission already granted in the
simulator UI. A failed probe retains its helper so consent can be granted.
This successful simulator round-trip does not certify physical-device passkeys,
background scheduling, iCloud behavior, or phone-copy removal. RAW+JPEG creation
API support is reported, but real camera RAW+JPEG files still require a separate
restoration fixture.

## Run against a server

1. Open `Nephos.xcodeproj`, or install the built simulator app.
2. Enter the canonical HTTPS base URL, including any deployment base path.
   Probe `/v1/config`, inspect its server ID and issuer, and explicitly approve.
   Confirm those values independently with the operator.
3. Configure the native public OIDC client **`nephos-ios`** and the pinned
   Keycloak PIN provider. Allow the `openid profile offline_access` scopes and
   publish discovery plus RS256 JWKS on the issuer origin. Do not configure a
   client secret. No redirect URI or Associated Domains capability is needed
   for PIN login.
4. Enter the account email and continue. Only after the server validates the
   known enabled account does the PIN-entry screen appear. Ask the administrator
   for the PIN displayed in the private console, then
   choose a library.
   Gallery access does not require Photos permission.
5. In Backup, explicitly grant Photos access, select originals with the native
   picker, or independently enable automatic backup in Settings.
6. Resume reconciles stable upload IDs and the server's received parts before
   sending missing chunks. Completed originals appear in the actual gallery.
   The grid requests 512-pixel previews; opening a photo requests a 1280/2560-pixel
   preview appropriate to the screen, never the original as an automatic fallback.
   Preview cache entries are isolated by account, asset and size, and remain bounded.
   If a preview is unavailable, retry or explicitly export the original. Videos use
   authenticated bounded range playback. Use **Export all originals** to verify
   every resource and save files plus a manifest, or **Save back to Photos** for
   supported unedited resource combinations.

For DEBUG-only development, the user may explicitly approve HTTP on localhost,
canonical private IPv4 addresses, or `.local` hosts. This sends sensitive data
unencrypted: use synthetic media on a trusted development network. It does not
disable certificate validation. Release always requires HTTPS, including the
issuer and discovery endpoints. A phone's `localhost` is the phone, not the
development computer. Passkeys still need a correctly configured, stable RP
domain and the identity provider's secure-origin requirements.

No tokens are stored in UserDefaults, URLs, logs, or the upload ledger. Rotating
credentials live only in Keychain (`AfterFirstUnlockThisDeviceOnly`), with a
serialized refresh task. Authentication validates state, nonce, callback
binding, issuer, audience/authorized party, token lifetime, and RS256 signatures.
Redirects on API/token/JWKS/media/background-upload requests are refused.
No arbitrary authentication challenge/certificate bypass is installed.

## Operational UI and storage

- **Gallery:** selected library, retained revision-frozen snapshot, stable
  timestamp + ID pagination, explicit older-page loading, semantic visible
  anchor preservation on refresh, **Newest**, and year/month/day count navigation.
  A protected, account/server/library-bound 300-item metadata window survives
  relaunch. Offline/failed refresh is explicitly stale; original media is not
  pinned offline. Snapshot expiry rebases once; revoked/denied access clears
  persisted metadata and sensitive views. Preview absence does not block originals.
- Delta catch-up streams bounded pages through the new snapshot's fixed revision;
  no new persistent token/window is committed until every page is validated.
  The target snapshot re-queries the bounded visible window, rather than treating
  unseen delta items as a complete local million-asset index. Durable mappings
  retain remote-removal suppression outside that window. Gallery synchronization
  merges tombstones without overwriting concurrent upload progress.
- **Backup:** permission/limited-access explanation, native selection (20 items),
  explicit resume, exporting/uploading/verifying/ready/paused/failed/source-changed
  status, recent 100 mappings, whole-item complete/incomplete status, resource-set
  publication errors/retries, and phone-removal review.
- **Settings:** automatic backup and automatic cleanup offers are independent
  and **OFF by default**. Cellular/expensive uploads are also off. Cleanup opt-in
  additionally requires acknowledging synchronized-Photos/single-copy warnings.
- Atomic, file-backed versioned ledgers are partitioned by a SHA-256 key over
  canonical URL, server ID, issuer and validated account subject. They retain
  source IDs/revisions/resource manifests, stable upload IDs, hashes/sizes,
  part acknowledgements, retry state, evidence, retention holds and removal
  outcomes. The version-1 ledger remains backward-compatible; additional
  source UTI metadata does not force legacy originals to be uploaded again.
  Capture dates come from `PHAsset.creationDate`, sent as optional
  `capturedAt` on the immutable upload intent.
- PhotoKit resources are exported without transcoding or stripping bytes,
  streamed to protected Application Support files, and hashed off the UI actor.
  Revision mismatch during export blocks the upload mapping. Missing staging
  is re-exported only from the same revision and must match the old hash/size.
- Every required PhotoKit resource (1–16) has a durable role, original filename,
  UTI, SHA-256, size and canonical committed asset ID. A stable set UUID is
  persisted **before export**, included in each constituent upload intent, and
  published only after every part has exact server evidence. Edited, Live Photo,
  RAW+JPEG and archive sets are never called whole-item ready just because one
  resource completed. Partial export/publication resumes even when new automatic
  discovery is off. TIFF/RAW and other unsupported MIME types use octet-stream
  while preserving the original UTI/name in the manifest.
- Staging budget: **10 GiB across accounts**, one resource export and one **4 MiB**
  chunk file at a time; individual originals max **8 GiB**, subject to free space.
  Exports stop at the remaining quota, reserving 64 MiB free-space headroom.
  A durable ledger is capped at **50,000 resource mappings and 50,000 sets per account**; reaching
  it pauses new exports rather than discarding correctness history. JSON ledgers
  are an MVP choice, not a million-item local metadata database.
- Preview cache: **32 MiB / 100-image NSCache target**, with downsampled images.
  Active SwiftUI views may additionally retain displayed images, bounded by the
  **300-asset** gallery window. Image viewer: **512 MiB** per file and downsampling
  to 4096 pixels; larger images remain available through full-resource export.
  Videos use `AVAssetResourceLoader` and authenticated **512 KiB** HTTP ranges,
  with at most eight active loader requests and a five-second preferred player
  buffer. Exact 206/Content-Range/length validation rejects an ignored Range.
  Bearers never enter player URLs; redirects are refused. No whole multi-GiB
  video file or permanent original cache is created for playback. Whole-file
  SHA-256 verification happens on export, not during ranged playback.
- **Export/restore:** download and verify all originals sequentially, with a
  **10 GiB complete-set/free-space budget**, before offering Files/share or Photos.
  Both original names/UTIs and a JSON manifest accompany export. Downloads use
  bounded file buffers; incomplete/hash-mismatched sets are never shared as
  complete. Temporary export files are removed on viewer exit/account transition.
  PhotoKit creation is gated by supported roles and the device's actual
  `supportsAssetResourceTypes` response. Every operation exposes failures.
- Completed upload staging is deleted after matching `/backup` evidence.
  Preview cache and gallery reset on account/library transitions; viewer files
  are removed on viewer exit, sign-out and next launch. Orphan export/part files
  are reconciled on account restoration without deleting active task bodies.
  Operational files are excluded from device/cloud backup. Sign-out cancels
  transfers and clears credentials/views; pending originals remain isolated for
  the same account's later resume. There is no unattended staging-discard action.
- Initial discovery scans at most 12 accessible assets per run, persists a
  checkpoint, then cycles for subsequent changes. Foreground automatic runs
  repeat approximately each minute. Existing queued work may resume even when
  *new automatic discovery* is off. Up to 20 pending uploads are attempted per run.
  Failures have 30-second exponential backoff capped at an hour; explicit Resume
  bypasses the wait. One failed item does not stop all later automatic items.

## Background behavior

Chunk bodies are file-backed `URLSessionConfiguration.background` uploads,
tagged with account/upload/part identity. Surviving tasks are reconciled before
new foreground resume work. Duplicate/timed-out requests use server-authoritative
status and immutable, idempotent part semantics. URLSession delegate handling and
OS completion callbacks are present. BGProcessingTask scheduling requests network
access with a minimum 15-minute delay, checks cancellation, checkpoints unfinished
work and completes expired task callbacks.

**The OS decides whether and when anything runs.** No continuously running worker,
silent-push guarantee, force-quit recovery guarantee, or guaranteed overnight
completion is claimed. Open Backup and Resume for deterministic user-driven
progress. A running background upload can outlive the short BGProcessing budget;
its server status is reconciled later. New cellular policy applies to new transfer
tasks. PhotoKit's original/iCloud fetch API offers a network-access switch, not
the full URLSession per-network controls: new cloud exports are deferred on an
expensive/constrained path when cellular is off, but a network change during an
existing PhotoKit export is not a strict cellular-use guarantee.

## Real phone-copy removal and safeguards

The client implements the agreed retention endpoint:

```text
POST /v1/assets/{id}/retention
{ id, sha256, size, available, holdId, retainedUntil,
  assurance: "single-volume-no-independent-backup" }
```

For each explicitly confirmed item (maximum 10 in a review):

1. Require a server-committed upload mapping, Photos permission, and a
   **single, supported, unedited photo or video resource**.
2. Re-fetch the local identifier and compare source revision/resource manifest.
   Export its current original again and require exact SHA-256 and byte length.
3. Obtain a **fresh online** retention hold, whose server implementation rehashes
   the retained original. Require matching asset/hash/size, availability, known
   single-volume assurance, and **more than one hour** until expiry.
   Cached ordinary `/backup` evidence alone never authorizes deletion.
4. Persist that hold and current evidence; require evidence less than 60 seconds
   old and re-fetch/recheck the Photos revision immediately before submission.
5. Require app foreground, persist `awaiting-system-confirmation`, and call
   PhotoKit `performChanges` / `PHAssetChangeRequest.deleteAssets`. Honor iOS
   cancellation/errors; persist success only after Photos reports completion.
   Relaunch never blindly replays a pending destructive request.

Automatic cleanup means automatic **foreground offers**, not silent deletion.
The in-app warning explicitly covers iCloud/other-device/shared-library deletion,
single-volume (not independently replicated) server storage, operator/disk risks,
and Recently Deleted. The subsequent iOS system dialog is also required.
No server deletion/GC endpoint is called.

Cleanup allowlist: single original JPEG, PNG, HEIC/HEIF, TIFF, GIF, QuickTime or
MPEG-4 video with a known source modification revision. Live Photos, RAW/pairs,
multiple resources, adjustment/edited resources and other unsupported resources
are archived as complete sets but **never become cleanup-eligible**. New
single-resource mappings additionally require successful whole-set publication.
The viewer can request and persist a complete-set retention hold, but that
does not enable destructive cleanup for compounds. This does not
claim restoration of Photos albums, edits, favorites, shared-library state or
compound-media semantics.

**Unavoidable/current gaps:** server holds and Photos are not a distributed
transaction. Once iOS owns a delayed confirmation dialog, the app cannot provide
a revision-conditional delete or atomically cancel a dialog whose hold expires
after an extreme delay. The 30-day backend hold and >1-hour submission threshold
reduce—not eliminate—this gap. Concurrent Photos changes between the final check
and system execution cannot be fenced by PhotoKit. A crash after system removal
but before ledger persistence leaves an uncertain outcome, not assumed success;
missing/revoked sources are blocked on later review. Server holds protect
application references, not disk failure, ransomware or operator deletion.

## Remaining acceptance work

### Implemented restore contract and qualification boundary

| Source | Backup/export | Save back to Photos | Phone cleanup |
|---|---|---|---|
| Unedited single JPEG/PNG/HEIC/HEIF/TIFF/GIF | Exact original + manifest | Native photo creation, subject to runtime format/API support | Existing single-resource revision/hash/fresh-hold guards only |
| Unedited single QuickTime/MPEG-4 video | Exact original + manifest; ranged viewing | Native video creation | Same existing guards |
| Unedited Live Photo | Every original photo + paired video, complete manifest | Native `.photo + .pairedVideo`; requires intact pairing metadata and runtime support | **Blocked** |
| Unedited RAW+JPEG | Every original/alternate photo, preserving RAW UTI | Native `.photo + .alternatePhoto` only if runtime accepts it | **Blocked** |
| Edited, adjustment, other multi-resource archive | Every required resource + full manifest | **Blocked**; export all verified files instead | **Blocked** |
| Unknown single resource / unsupported format | Exact bytes and metadata preserved | Only when Photos can create the original format; errors surfaced | **Blocked** outside the explicit allowlist |

This table describes implemented code paths, not a device certification.
The network fixture's “Live Photo” resources intentionally contain synthetic
protocol bytes; it proves archive completeness, not a decodable paired movie.
Actual Photos byte-round-trip remains unpassed as explained above. RAW+JPEG
requires representative camera originals. No albums, favorites, edit history,
shared-library relationships, or implicit lossless format conversion are promised.

No registered developer team or physical-device certification was available.
Before using irreplaceable media, perform signed-device E2E probes for:

- known-user PIN issuance/expiry/one-use behavior, OIDC token verification,
  access-token `sub` and the full provision/email/PIN/own-library/refresh/revocation
  journey in `scripts/admin-smoke.py` (required by backend integration CI),
  offline refresh, device revocation, account/server switches, and the
  deployment's issuer hostname and HTTPS trust chain;
- selected/limited/denied/revoked Photos access, cloud-only originals, low disk
  space, source edits, supported formats and compound/edited rejection;
- interruptions/reboots/force quits, surviving URLSession task callbacks,
  BGProcessing expiry, network-policy changes and actual overnight behavior;
- real gallery image/video formats and authenticated retrieval;
- retention expiry/assurance failures, changed hashes/sources, user cancellation,
  iCloud/shared-library consequences and post-removal reconciliation.

Remaining deliberate UI scope: no Bonjour discovery, APNs, semantic search,
collaborative editing, server trash, or offline original pinning. Read-only
known-user sharing and People correction UI are implemented. Files/share-sheet
export, supported save-back, retained offline metadata, direct date navigation,
and large-video range playback are implemented. The durable ledger is still a
bounded MVP JSON ledger, not a million-item local database. No physical-device
passkey/background/deletion gate is marked passed.

## Remaining features

| Area | Not implemented or not yet qualified |
|---|---|
| Semantic search | Image/video vector indexing, natural-language queries and combined scene + person search. Current person search matches case-insensitive name/alias substrings; filename filtering covers only the loaded window. |
| Albums and favorites | Server album CRUD, album covers/membership, favorites and associated synchronization. The Albums tab currently exposes libraries and sharing, not fabricated collections. |
| More ML/video | Video face recognition, automatically suggested duplicate-person review, representative large-library accuracy/scaling, optimized video transcodes and adaptive streaming. Original-range playback already works. |
| Background updates | APNs device registration, durable push delivery and remote update hints. Existing background URLSession/BGProcessing backup is OS-scheduled, not guaranteed overnight execution. |
| Offline/mobile completeness | Pinned offline originals, Bonjour discovery, million-item local indexing, complete localization, and broad Dynamic Type/VoiceOver/device qualification. |
| Media lifecycle | User metadata/date editing and collaborative editing. Server trash and marker-only restore are available from the gallery menu; deleted originals are eligible for scheduled purge after 30 days. Current shared grants are read-only. |
| Release acceptance | Physical-iPhone PIN/OIDC login and revocation, signing/production HTTPS, interruptions/force-quits, actual overnight backup and Photos/iCloud behavior qualification. RAW pairs need representative device qualification. |
| Platform roadmap | Android, Helm/Swarm deployment, alternate storage/database adapters, HA, independent full recovery including the optional Faces database, and future books/Jellyfin-style applications. |

This list distinguishes absent product features from unpassed release checks.
No provider login bypass or synthetic production gallery was added to hide the
remaining setup/device prerequisites.

## Native completion change inventory

The original native foundation inventory is below. The approved-design increment
adds `Core/Presentation.swift`, `Core/Social.swift`, `UI/Design.swift`,
`UI/PeopleViews.swift`, `UI/SharingViews.swift`, native presentation/social tests
and `Qualification/UIQualification.swift` with its runner. It also updates the
root documentation and preserves the accepted design source under `design/ios/`.
No backend schema or deployment change is required for these native screens.

- Core: `Nephos/Core/{Models,Ledger,Network,ResourceSets,Snapshots,RangedMedia}.swift`
- Platform: `Nephos/Platform/{AppModel,PhotosLibrary,Media,RangedPlayer,Restore}.swift`
- UI: `Nephos/UI/Views.swift`
- Tests: `Tests/NephosCoreTests/{CoreTests,GalleryResourceTests,NativeBackendTests}.swift`
- Qualification: `Qualification/PhotosQualification.swift`,
  `run_photos_qualification.py`, `run_native_e2e.py`
- Project/configuration: `generate_project.py`, `Nephos.xcodeproj/project.pbxproj`,
  `Nephos/Info-Debug.plist`, `Nephos/Info-Release.plist`
- Documentation: `README.md`
