# Private administration

The Nephos console runs Flask behind Gunicorn, not Python's development HTTP
server. Operators sign in using Keycloak's normal browser form through OIDC
Authorization Code + S256 PKCE. Authlib validates state, nonce, signature,
issuer, audience and token lifetime. A signed master-realm `admin` role is
required; photo-library accounts do not grant operator access.

The console never receives the operator password. The one-shot `admin-init`
job uses the bootstrap credential to configure its confidential OIDC client;
the running console does not receive that credential. No password grant,
service-account grant, implicit flow or wildcard redirect is enabled for the
console client. Keycloak handles credential errors, brute-force protection
and the operator's configured authentication/MFA policy.

## Media-user sign-in

The primary administrator and mobile enrollment flow is now described in
[admin-console.md](admin-console.md): known user, one-time QR, independently
revocable device session. New accounts do not require email. The console no
longer uses a PIN-request dashboard as the primary onboarding interface.
Existing device refresh sessions survive the change.

### Legacy provider compatibility

The admin console is the only account-creation path. Creating a known account
does not email a credential. The legacy email/PIN provider contract remains
available for existing configured accounts and compatibility qualification;
it is not the new native client's primary login. Public
`POST /realms/nephos/nephos-admin/request-pin` accepts bounded JSON
`{"email":"known@example.test","clientId":"nephos-ios"}` and generates an eight-digit,
one-use, 30-minute PIN only for a known enabled account. Its response contains
only `{"expiresIn":1800}`, never the PIN or user ID. Invalid input returns 400,
unknown/disabled accounts 404, rate limits 429 with `Retry-After: 60`, and
dependency failures 503. Email is trimmed, lowercased and format-validated.
Requests are limited to ten per IP per minute and one per normalized email per
60 seconds. After cooldown, repeated pending requests return the original
remaining lifetime without replacing the PIN.

The private compatibility endpoint
`GET /realms/nephos/nephos-admin/pin-requests` requires
`X-Nephos-Identity-Service-Key`; neither that key nor operator credentials
are available to the native client. The legacy response is
`{"requests":[{"email":"known@example.test","username":"known","pin":"12345678","expiresAt":"...Z"}]}`.
Requested PIN ciphertext (AES-256-GCM, random IV, account-bound authenticated
data, a domain-separated key derived from `NEPHOS_PIN_PEPPER`), expiry and the
peppered HMAC verifier share one single-use record. PINs are never logged.
Consumption, revocation, expiry, disabled users and manual reissue remove the
requested entry. Legacy private manual issuance returns the PIN only in its
response, replacing the earlier PIN; it is not cached in the operator session.
Invalid grant attempts are
limited to ten per account per 15 minutes. Keycloak and the public API must use
HTTPS at the deployment edge.

Legacy clients submit the email and PIN to the Keycloak token endpoint using
the `urn:nephos:params:oauth:grant-type:login-pin` OAuth extension grant. It
receives normal Keycloak OIDC access, ID and offline refresh tokens; Nephos does
not mint a parallel token format. The PIN is the bootstrap credential for that
device, not a reusable password. API access tokens last five minutes. Offline
refresh sessions have no idle or absolute timeout, so they persist until the
user is disabled or an operator revokes the device session.

The private console can list/revoke a single Nephos iOS device. Revocation
removes its Keycloak offline session and is checked immediately by each
protected API request through Keycloak token introspection. Disabling platform
access also disables the Keycloak user and removes all recorded Nephos iOS
sessions. APIs fail closed with HTTP 503 if Keycloak cannot report session
status; clients should retry and must not interpret that outage as a sign-out.

The PIN grant and its admin resource use Keycloak's internal provider SPIs.
They are built into the custom `nephos-keycloak:26.8.1` image and intentionally
pinned to Keycloak 26.8.1. Upgrades must rebuild the provider and pass
`scripts/identity-production-smoke.py` against the proposed Keycloak version
before deployment. The API introspection client and PIN HMAC pepper are
separate generated secrets (`API_INTROSPECTION_CLIENT_SECRET` and
`NEPHOS_PIN_PEPPER`). The identity extension also uses
`IDENTITY_ADMIN_SERVICE_KEY`, distinct from the library administration key.
Keep all three in the protected environment and rotate them only as an explicit
credential migration.

## Deployment and upgrade

New deployments use `scripts/dev-env.py`. Existing deployments must first run:

```sh
python3 scripts/upgrade-dev-env.py
docker compose up -d --build
```

Include your existing Compose/environment overrides in these commands. Do not
drop a LAN/HTTPS override while upgrading. The upgrade helper adds missing secrets, including `ADMIN_OIDC_CLIENT_SECRET`,
`ADMIN_SESSION_SECRET`, `ADMIN_SESSION_STORE_PASSWORD`,
`API_INTROSPECTION_CLIENT_SECRET`, `IDENTITY_ADMIN_SERVICE_KEY` and
`NEPHOS_PIN_PEPPER`; existing credentials are not rotated.

Compose starts the private session store, completes `admin-init`, then starts
the console. Bootstrap is idempotent: it configures only its named client,
the master realm's explicit private frontend origin and brute-force protection.
It preserves other realm settings, users, credentials and the public `nephos`
realm. The client's scope permits the existing master `admin` role; bootstrap
does not assign that role to any user.

Defaults:

- Console: `ADMIN_PUBLIC_URL=http://localhost:18082`
- Private identity frontend: `ADMIN_IDENTITY_PUBLIC_URL=http://localhost:18081`
- Callback: exactly `<ADMIN_PUBLIC_URL>/oauth/callback`

Both values must be explicit origins. Non-loopback HTTP is rejected; private
remote access requires HTTPS with trusted certificates and network access
controls. Do not expose either administration console through public ingress.
Changing an origin requires rerunning bootstrap and restarting the console.
For local access, `127.0.0.1:18082` redirects to the canonical `localhost` origin
so cookies and callback validation are consistent. SSH forwarding must preserve
both configured local ports. Untrusted Host headers and cross-origin mutations
are rejected; forwarded headers do not silently redefine trusted origins.

## Sessions and failures

Tokens remain server-side in the password-protected Valkey session store on a
dedicated internal network. It has no host port, no disk persistence and a
64 MiB memory limit with no eviction; capacity errors are explicit failures.
The browser receives only a random HttpOnly, SameSite=Lax session cookie.
HTTPS deployments also set Secure. Lax permits the top-level OIDC callback;
Flask-WTF CSRF tokens and an exact Origin check protect all mutation forms.

Session IDs rotate after authentication. Sign-in attempts expire after ten
minutes; operator sessions have an absolute eight-hour deadline and do not
slide indefinitely. Requests using the same session are serialized across
workers until the final session write; concurrent reads/refreshes cannot
recreate a session after logout. Lock waits and dependency calls are bounded.
Access tokens refresh on demand; refreshed ID tokens and operator roles are revalidated.
Provider session expiry or a rejected refresh requires sign-in again.
Keycloak token lifetimes bound how long a previously issued operator role may
remain usable; do not treat the UI session lifetime as a revocation guarantee.

Sign out invalidates the local session and ends its provider session. A copied
old cookie cannot restore a logged-out session. Provider failures are shown
explicitly, including a provider failure after local logout. Session-store
failures block authentication/actions instead of falling back to local sessions.
Restarting the console preserves sessions; restarting the nonpersistent session
store signs operators out. Media, accounts and libraries are unaffected.

Actions use POST/Redirect/GET to avoid browser refresh resubmission. Provisioning
spans identity and library services, but durable Library administration
operations now record progress, identity provenance and immutable command
payloads. The reconciler resumes accepted operations after logout/restart.
The console reports authoritative operation status, not transactional rollback
or successful completion merely because a request timed out.

Request telemetry records bounded method/status fields, not callback URLs,
cookies, credentials or request bodies. Gunicorn access logging is not enabled.
For failure diagnosis, inspect `admin-init`, `admin-console`, `admin-sessions`
and Keycloak health/logs without dumping their environments or session values.
Do not restore stale operator sessions from backups.

## Verification

```sh
python3 -m pip install -r scripts/admin-requirements.txt
python3 -m unittest discover -s scripts -p test_admin_auth.py
python3 -m pip install -r scripts/browser-requirements.txt
python3 -m playwright install chromium
python3 scripts/admin-browser-smoke.py
python3 scripts/admin-smoke.py
```

In an isolated development stack only, lifecycle fault injection can also
refresh tokens, restart the console, pause/recover the session store and expire
the test session. This temporarily interrupts administration; do not run it
against an instance in use:

```sh
python3 scripts/admin-session-smoke.py \
  --console-container "$(docker compose ps -q admin-console)" \
  --session-container "$(docker compose ps -q admin-sessions)"
```

The browser check uses the actual Keycloak form, including an incorrect
password, successful login, session reload, missing-CSRF rejection, logout,
cookie replay and a non-operator account. Fixtures are deleted afterward.
The provisioning smoke check uses the same OIDC form/session flow rather than
a test-only authentication path. These scripts are for development deployments,
not production realms. Never save browser storage state or authentication traces
into publishable artifacts.
