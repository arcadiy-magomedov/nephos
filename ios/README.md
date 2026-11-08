# Nephos for iOS

The app is being rebuilt. Its current scope is **sign-in only**:

- The approved light/dark mobile QR flow: Sign in, Scan, Connecting, and QR error.
- Camera scanning or Apple's Photos picker, without requesting full Photos access.
- A minimal signed-in confirmation, remote revocation, and explicit device-only sign-out.
- Secure enrollment recovery and automatic restoration of saved sessions.

There is no gallery, backup, library picker, People, sharing, or media restoration
in this implementation. Backend capabilities and approved Penpot designs are
unchanged. iOS 17 or later is required; the app has no third-party dependencies.

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

The optional real-enrollment test skips without a fresh invitation image.
[Real-service qualification](../deploy/native-qr-ci.md) provisions an isolated
Keycloak/Library fixture and supplies that image; it exercises a persisted request,
a deliberately lost exchange response, cold restoration, and actual token refresh.
It never injects bearer tokens or bypasses TLS. Use a disposable simulator for the
fixture, not an existing development device.

## Persistent session contract

On cold launch and foreground return the app validates the saved server identity
and probes the authenticated Library API before showing the signed-in state.
Restoration starts on a neutral progress screen, not the sign-in screen.
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
[the server contract](../deploy/keycloak/QR-ENROLLMENT.md) for upgrade details.

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
