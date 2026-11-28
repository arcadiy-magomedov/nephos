# Nephos for iOS

The app supports **QR sign-in, a local Photos gallery, and optional automatic backup**:

- The approved light/dark mobile QR flow: Sign in, Scan, Connecting, and QR error.
- Camera scanning or Apple's Photos picker, without requesting full Photos access.
- A date-grouped, lazily paged Photos gallery with All, Photos, and Videos filters.
- Photo viewing with zoom/panning and previous/next navigation.
- Video playback, seeking, mute, and full-screen controls.
- Original-quality file sharing through the native iOS share sheet.
- Explicit local-only deletion with both Nephos and system Photos confirmation.
- Remote revocation and explicit device-only sign-out.
- Secure enrollment recovery and automatic restoration of saved sessions.
- Durable growing upload batches with pause/resume, retries, grouped history and error details.
- All-networks, Wi-Fi-only and Disabled automatic-upload policies (Disabled by default).
- Shared Gallery/Uploads thumbnails with real byte-weighted radial progress.
- Live Photo playback and preservation of original compound resources during backup.

Uploads use the verified QR-enrolled server connection; no upload server is
hardcoded in the application or Info.plist. Shared media, Search,
and People remain unavailable. Download original is
not shown for items already in Photos, avoiding duplicate imports. The gallery
contains the permitted Photos-library assets, including iCloud-managed items;
opening/sharing those may require an iCloud download. It never substitutes
Nephos upload/backup badges for local state: the backed-up badge requires the
complete server resource-set commit.

Photos access is requested only from the gallery's explicit permission action.
Limited, denied, restricted, and changed permissions are respected; limited
access can be managed inside the app. **Delete from Photos** can propagate to
iCloud and other devices and does not guarantee immediate space reclamation.
There are no server-delete or Delete everywhere actions in this increment.
Editable designs are unchanged. iOS 17 or later is
required; the app has no third-party dependencies.

## Upload architecture

`Core/Transfers` and `Platform/Transfers/BackgroundFileUploader.swift` implement
a file-type-independent, file-backed background URLSession transport. Callers
supply a local immutable file, an HTTPS POST/PUT/PATCH request, a stable task UUID,
scope, exact byte count and opaque recovery context. The transport preserves the
request's MIME type, authentication and network policy; missing MIME types default
to `application/octet-stream`. It does not inspect extensions, decode files,
require Photos access or apply the media API's 4 MiB chunk / 8 GiB resource limits.
Empty files are valid at this transport layer.

```swift
let descriptor = FileUploadDescriptor(
    id: jobID, scope: "books", byteCount: fileSize, context: recoveryContext)
var request = URLRequest(url: enrolledServerUploadURL)
request.httpMethod = "PUT"
request.setValue("application/epub+zip", forHTTPHeaderField: "Content-Type")
request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
try await uploader.enqueue(descriptor, request: request, file: bookFileURL)
```

Create one `BackgroundFileUploader` per stable session identifier, keep it alive,
and recreate it on every app launch. Its `FileUploadEventStore` durably records
HTTP outcomes before the finished-events callback; acknowledge results only
after the caller has persisted its own state. Opaque context must not contain
credentials. Keep source files unchanged and readable while transfers are active.
Authentication renewal and server-side finalization belong to the caller, not
the generic transport. Background URLSession follows redirects itself, so upload
endpoints must not redirect; a final cross-origin response is reported as an error.

`MediaUploadTransport`, `UploadCoordinator` and the Photos source are adapters
above that transport. They apply the existing immutable 4 MiB chunk protocol,
hash originals, preserve all compound resource bytes/roles and commit the complete
manifest. The current media API retains its own media-specific validation.
A Live Photo counts once, and succeeds only after every required resource and
the manifest are committed. Sharing a Live Photo exports its original still and
paired video as separate files; it does not promise that every share destination
will reconstruct a native Live Photo.

The persistent batch includes the entire discovered eligible inventory, not just
dispatched URLSession tasks. New Photos assets join the current batch; failed
items keep it open. Counters reset only after a reconciliation finds the batch
fully successful. Per-item progress uses resource bytes, while the Library bar
uses successfully committed items divided by the growing batch total.

Background URLSession continues queued transfers while iOS suspends the app.
Photos discovery and staging run during foreground use and opportunistic
BGAppRefresh/BGProcessing opportunities, not a guaranteed polling interval.
Force-quitting cancels URLSession background transfers and prevents automatic
relaunch until the user opens the app again. This implementation deliberately
does not use the PhotoKit upload extension: Apple's documented
`BackgroundUploadURLBase` configuration has no documented runtime override for
arbitrary QR-selected self-hosted servers in the installed SDK.

## Run and check

```sh
python3 ios/generate_project.py
open ios/Nephos.xcodeproj
swift test --package-path ios
xcrun swift-format lint --strict --recursive ios/Nephos ios/Tests ios/Qualification
xcodebuild -quiet -project ios/Nephos.xcodeproj -scheme Nephos \
  -configuration Debug -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

Select your signing team for a physical device. Codes must reference a canonical
HTTPS server with a trusted certificate. Neither Debug nor Release bypasses TLS.
The only required device permissions are camera access and local network access
when the chosen server is on the LAN.

Run native Keychain, QR-error, camera-fallback, and adaptive-layout checks in an
isolated test application:

```sh
python3 ios/qr_qualification.py --simulator SIMULATOR_UUID
```

Include the local gallery's native permission, photo/video, share, deletion,
and adaptive-layout checks on a **disposable simulator**:

```sh
python3 ios/qr_qualification.py --simulator SIMULATOR_UUID --local-gallery
```

These checks add generated Photos fixtures and delete only a recorded fixture
identifier, never an arbitrary item from the device's library.

Verify the generic file transport on a **disposable simulator**:

```sh
python3 ios/file_upload_qualification.py --simulator SIMULATOR_UUID
```

This uses synthetic PDF/EPUB/custom-file payloads, a private loopback HTTPS
receiver and certificate trusted only in that simulator. It stops only the
fixture app's process, verifies transfers still finish with exact bytes and MIME
types, then resumes it and checks persisted completion results. No Photos access,
personal files or live Nephos deployment are involved.

The optional real-enrollment test skips without a fresh invitation image.
[Real-service qualification](native-qr-ci.md) provisions an isolated
Keycloak/Library fixture and supplies that image; it exercises a persisted request,
a deliberately lost exchange response, cold restoration, and actual token refresh.
It never injects bearer tokens or bypasses TLS. Use a disposable simulator for the
fixture, not an existing development device.

## Persistent session contract

On cold launch the app restores the account from the device Keychain and shows
the local gallery without waiting for the network. Until the Keychain read
finishes, it shows only the app background, not a session-refresh screen.
On foreground return it keeps the current gallery/viewer in place and validates
the saved server identity and authenticated Library API silently, reusing the
same renewal coordinator. Temporary failures keep local Photos usable and
display a retryable connection notice. Definitive revocation returns to sign-in.
This does not grant offline access to protected APIs: every server request still
requires authentication and server-side authorization.
Mutable upload limits are not part of server identity.

Access tokens last five minutes in the repository's Keycloak realm. The next
request renews a token with fewer than sixty seconds remaining; there is no
background timer or requirement to keep iOS running. Concurrent renewals share
one operation. Replacement credentials are persisted before they become active.

The checked-in Keycloak realm config sets offline-session inactivity to **180
days** (`15552000` seconds) and disables the absolute offline-session maximum.
Successful renewal extends the inactivity window. If the device cannot renew
for 180 days, it must be enrolled again. The app renews when access is needed;
iOS background execution is opportunistic, not a guaranteed keepalive.

New QR enrollments require DPoP in both the client and the checked-in realm.
Existing saved legacy sessions remain usable without being silently rebound.
Realm import alone does not upgrade existing deployments: the idempotent
`admin-init` bootstrap installs the mobile policy and 180-day timeout while
preserving users, sessions, and unrelated policies. See
[the server contract](qr-enrollment.md) for upgrade details.

- Only documented terminal session/account/credential-expiry errors (not every `invalid_grant`)
  or rejection after one authenticated refresh retry require sign-in again.
- Network, TLS, discovery, server-identity, Keychain, and temporary service errors
  preserve credentials and offer retry; they do not grant offline API access.
- Administrator revocation, disabled accounts, lost Keychain credentials, or
  local sign-out can end the session.
- Remote sign-out uses the discovered RFC7009 revocation endpoint with a fresh
  same-key proof and requires HTTP 200 before deleting credentials.
  Device-only sign-out is explicitly separate and does not claim remote revocation.

New qualified enrollments bind refresh tokens to the enrollment P-256 key.
Each exchange, refresh, receipt recovery, and revocation generates a fresh ES256
DPoP proof; access tokens remain five-minute Bearer tokens. The client verifies
ID/access signatures. Keycloak's HS512 refresh credentials are opaque: their
receipt is authenticated by nonredirecting HTTPS, not public JWKS verification.
The client checks returned identity/lifetime metadata and `cnf.jkt` consistency,
rejecting key changes or bearer downgrade. Decoded refresh claims never authorize
API access. Nonce negotiation permits one retry with a new proof. Proof, clock,
and configuration failures preserve the session.

Single-use refresh rotation is deliberately disabled: the last durable refresh
token remains usable with the same device key after a lost response, but only
within the actual finite server lifetime described above. Existing bearer sessions
are not silently rebound; protection requires a new admin-authorized enrollment.

Credentials and the enrollment journal retain the existing Keychain service,
account IDs, encoding, and account hashes. Legacy credentials migrate before the
old record is removed. Storage uses
`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`: it is device-local,
non-synchronizing, and unavailable until first unlock after restart. A failed
Keychain deletion is reported, not presented as successful sign-out. Production
Keychain operations run on a dedicated actor rather than blocking the UI.

The QR's immutable request ID, nonce, installation ID, and P-256 key are saved
before exchange. A crash or lost response resumes that same request, within the
server's bounded recovery window. Credentials and the device key are committed
atomically. New physical-device keys use CryptoKit Secure Enclave P-256 with an
opaque Keychain-stored representation and no per-renewal biometric prompt.
Previously saved software keys remain readable; they cannot be imported into the
Secure Enclave. Simulator and macOS unit tests explicitly use software keys, so
they do not qualify hardware protection. Bearer access tokens remain outside the
DPoP constraint; full API DPoP is separate scope.
