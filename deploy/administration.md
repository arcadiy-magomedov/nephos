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

## Deployment and upgrade

New deployments use `scripts/dev-env.py`. Existing deployments must first run:

```sh
python3 scripts/upgrade-dev-env.py
docker compose up -d --build admin-console
```

Include your existing Compose/environment overrides in these commands. Do not
drop a LAN/HTTPS override while upgrading. The new settings are
`ADMIN_OIDC_CLIENT_SECRET`, `ADMIN_SESSION_SECRET` and
`ADMIN_SESSION_STORE_PASSWORD`; existing credentials are not rotated.

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
still spans identity and library services: if a dependency fails midway, inspect
existing state before retrying; the UI reports this limitation rather than
claiming transactional rollback. This is an existing platform gap, not a
production-readiness certification of provisioning.

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
