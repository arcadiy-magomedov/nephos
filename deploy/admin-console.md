# Administrator console

The console is an operator-only Flask/Gunicorn application. It is not exposed
through the public media edge. Existing Keycloak OIDC/PKCE, server-side sessions,
CSRF, exact-origin checks and signed operator-role verification remain required.
Media users cannot become operators by being created in this console.

## Screens and operations

- **Обзор:** authoritative user/library totals, unfinished administration
  operations and independently measured storage/processing stages.
- **Пользователи:** paginated search and access filters, persistent account
  creation, editable display name and directory visibility, access changes,
  actual devices and single-device revocation, invitations and real QR display.
- **Медиатеки:** paginated library search, creation, renaming, recorded owner,
  direct memberships and share-derived access to all or selected media.
- **Состояние сервисов:** fixed private readiness probes, observation times,
  timeouts and optional-not-installed states. HTTP readiness alone is not
  evidence that a worker is progressing.

All navigation and mutations work with server-rendered forms without
JavaScript. QR countdown/status refresh is progressive enhancement; without
JavaScript the user detail page supplies authoritative invitation/device state.
No records are seeded and no browser-local model stands in for persistence.

Creating a user requires a login and display name, not email. Logins are
lowercased immutable identifiers of up to 64 ASCII letters/digits, dot,
underscore or hyphen, beginning with a letter or digit. A personal library is
created automatically. Existing email, libraries, media and sharing are kept.

Provisioning and profile/access commands are durable operations. An accepted
command has an immutable ID and payload and survives operator logout or process
restart. The operation page shows pending/completed/failure state; retry resumes
the same command. A timeout is not reported as successful provisioning or
revocation. Separate profile/access revisions prevent an old directory form
from reenabling a disabled account.

New libraries record an administrative owner without changing existing
membership, uploader or sharing authorization. Legacy ownership is not guessed:
only unambiguous single-member libraries can be designated automatically.
Unassigned libraries allow explicit initial designation to an existing direct
member. This is not an ownership-transfer or media-permissions editor.

## QR device enrollment

Configure `NEPHOS_PUBLIC_ORIGIN` to the canonical trusted HTTPS media origin.
It must match the public Keycloak realm issuer and the `/v1/config` identity
configuration. `compose.tls.yaml` sets it from `PUBLIC_HOST`; custom LAN/TLS
overlays must set it explicitly. Plain HTTP development Compose is not a
trusted mobile enrollment deployment.

Run the existing environment upgrade helper to create missing secrets without
rotating old credentials. `NEPHOS_QR_DELIVERY_KEY` is separate from operator
sessions, service keys and the legacy PIN verifier; never put it in a QR.
Include every currently used environment/Compose overlay during upgrades.

The operator creates a known account, opens its detail and issues a QR.
The QR contains a versioned HTTPS origin and a short-lived invitation credential,
not an access/refresh token. It expires after ten minutes and connects one
independently revocable device. It is shown only in the issuance response.
Replaying the issuance command returns metadata without exposing the credential
again; uncertain delivery requires cancellation before issuing a replacement.
Invitations remain visible in the user detail, so an active code is not hidden.

The iOS client scans with its camera or imports a local QR image. It validates
the payload and server configuration, proves possession of its persisted device
key, obtains normal Keycloak tokens and saves the session in Keychain.
Lost exchange responses can be recovered only by the same bound key/request
within the bounded delivery window and only while the original session remains
valid. Revocation, cancellation and access-generation changes override recovery.
Existing authenticated installations retain their sessions.

Do not expose provider user-management/invitation-list endpoints through public
ingress. The public edge permits enrollment challenge/config and normal OIDC
routes but denies private provider management routes. No certificate bypass or
manual server-discovery wizard is part of the QR flow.

## Data, availability and recovery

Storage bytes describe the actual mounted volume; available capacity is not
a per-user quota. Upload verification, outbox publication, face work and broker
ready/unacknowledged messages are separate counts, not distinct photos.
Missing/stale observations are not displayed as zero or healthy.
`ADMIN_FACES_URL` is configured by the Faces Compose overlay; absence means
Faces is not installed, whereas an unreachable configured Faces service is an
availability failure.

Additive database migrations preserve existing data. After QR cutover, reverting
to older authentication binaries is not a supported rollback. Test and use
forward repair or coordinated restore. Before accepting traffic after a restore,
invalidate restored invitation/receipt state and rotate its delivery generation/
key; do not restore operator sessions. Restarting the nonpersistent Valkey store
signs operators out but does not remove media or media-user device sessions.

## Qualification and release gates

Never run fixture creation/deletion or outage injection against a deployment in
use. Use a fresh checkout/environment and uniquely named disposable Compose
projects/volumes. `deploy/admin-test.compose.yaml` provides separate loopback
ports for local qualification; it is not a production overlay.

```sh
python3 scripts/admin-test-tls.py
python3 scripts/admin-tests.py
python3 scripts/admin-smoke.py
python3 scripts/admin-browser-smoke.py
python3 scripts/admin-ux-smoke.py
```

The browser and database checks use real services. HTTPS qualification uses a
throwaway CA added to the test trust store, never disabled TLS verification.
Keep QR credentials, browser storage, cookies and authentication traces out of
published evidence. Physical-camera behavior additionally requires an unlocked
iPhone; simulator image decoding is not physical-camera acceptance.

Each feature checkpoint must pass every CI job on its exact commit.
The repository requires the aggregate **Required CI** check on an up-to-date PR.
A draft PR is not a release; final native/browser/backend/upgrade acceptance,
green CI and explicit merge/deployment authorization precede production use.
