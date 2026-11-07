# Production QR enrollment (Keycloak 26.8.1)

The existing provider exposes private identity operations and a normal OAuth
grant, not another token issuer. Existing PIN and browser passkeys remain
compatible; refresh rotation/offline expiration policy is not changed.

## Configuration and migration

Set `NEPHOS_PUBLIC_ORIGIN` to the canonical HTTPS origin without a trailing
slash. Configure the same Keycloak hostname and Library public issuer. QR data
never uses a request Host, private identity URL, or operator URL.

Generate a separate 32-byte AES key as standard base64 in
`NEPHOS_QR_DELIVERY_KEY`; `dev-env.py` and `upgrade-dev-env.py` generate this
without displaying it or rotating existing credentials. Optional
`NEPHOS_QR_KEY_VERSION` defaults to `1`. Invitations bind both the configured
version and the key fingerprint. Replacing the key alone invalidates every
old active invitation and delivery receipt, including restored backups.
Rotate before accepting traffic after restore; revoke restored media sessions
as part of restore recovery. Keep the same key on every cluster member.

The JPA entity provider applies additive Liquibase migration
`META-INF/nephos-enrollment.xml` in the existing Keycloak PostgreSQL database.
Enable the `nephos-enrollment` realm event listener; realm import and idempotent
admin bootstrap do this while preserving other listeners. Admin-event details
remain disabled. The listener invalidates receipts on standard refresh/logout
and fences external user administration. PostgreSQL READ COMMITTED and
Keycloak's default persistent sessions/main-transaction updates are required.
No preview/stateless feature is required.

After QR cutover, rollback to old authentication binaries is unsupported:
restore and forward-fix instead. Added tables do not modify media/PIN data.

## Private service contract

Base `/realms/nephos/nephos-admin`, authenticated only by the distinct
`X-Nephos-Identity-Service-Key` credential. Public ingress must reject management
routes, including the normal Keycloak administrative API.

* `PUT users/{subject}/provision`:
  `{commandId,requestHash,login,displayName}` creates the predetermined UUID,
  disabled, without email, with provenance and only the offline-access role.
  Exact replay is safe; an unrelated subject/login/command conflicts.
* `GET users?cursor=<subject>&limit=100`: bounded stable-ID pages excluding
  service accounts, `{items,nextCursor,total}`.
* `GET users/{subject}` returns
  `{subject,login,displayName,enabled,revision,epoch,commandId}`.
* `PUT users/{subject}/profile`:
  `{commandId,expectedRevision,displayName}` advances revision only.
* `PUT users/{subject}/access`:
  `{commandId,expectedRevision,enabled}`. Disable advances epoch, invalidates
  invitations/PIN/receipts, removes all online/offline media sessions. Reenable
  cannot restore them. Repeated commands return current state without reexecution.
* Existing `GET users/{subject}/devices` and
  `DELETE users/{subject}/devices/{sessionId}` expose one logical device per
  session, including legacy browsers, and revoke both representations.
* `POST users/{subject}/invitations` `{commandId}` returns 201
  `{inviteId,status,createdAt,expiresAt,qr:{v:1,origin,inviteId,secret}}`.
  Command replay returns metadata only, never another credential.
  A lost issuance response requires explicit cancel then new command issuance.
* `GET users/{subject}/invitations` returns `{invitations:[metadata]}`;
  `DELETE users/{subject}/invitations/{inviteId}` returns cancelled metadata.
  Cancelling a claimed invite invalidates delivery, not the existing device;
  revoke the device explicitly to terminate its session.

New login: `[a-z0-9][a-z0-9._-]{0,63}`, immutable. Existing usernames/email are
unchanged. All UUIDs canonical lowercase; display names 1–100 characters.
Conflicting revisions/commands return 409; disabled issuance 409; unknown 404;
unauthorized 401; bounded issuance/challenges 429. JSON responses are no-store.

## Public device protocol

Allow only the enrollment config/challenge routes and the normal OIDC routes:

`GET enrollment/config` returns `{v:1,origin,issuer,clientId:"nephos-ios",
grantType:"urn:nephos:params:oauth:grant-type:qr"}`.

`POST enrollment/challenge` JSON:
`{inviteId,requestId,clientId:"nephos-ios",publicKey}`.
Public key is unpadded base64url X9.63 uncompressed P-256 point (65 bytes).
Response `{challengeId,challenge,expiresIn:60}`; challenge is base64url UTF-8
of newline-separated fields, without a trailing newline:

1. `nephos-qr-v1`
2. canonical origin
3. `nephos-ios`
4. invite UUID
5. persisted request UUID
6. base64url SHA-256(public-key bytes)
7. challenge UUID
8. base64url 32-byte random server nonce

Sign those bytes using SHA-256 ECDSA P-256, DER signature, base64url unpadded.
The Keycloak token endpoint receives form fields `grant_type`, `client_id`,
`invite_id`, `invite_secret`, `request_id`, `public_key`, `challenge_id`,
`signature`, `device_name`, `nonce` (persisted UUID),
`scope=openid offline_access`. Recovery uses the same immutable request/key/
nonce/name/scope with a fresh authenticated challenge. The secret is 32 random
bytes; only its SHA-256 verifier persists. Server expiry is ten minutes.

The durable claim, Keycloak online/offline user/client records and authenticated
AES-GCM delivery receipt commit in one JPA transaction using Keycloak's own
persistent adapters and session persister. Session ID equals the globally
unique request UUID. Normal TokenManager generates/signs all tokens. Durable
offline issuer/scope/nonce notes preserve standard refresh. No single-use cache
owns the claim. Receipt delivery lasts at most ten minutes after claim, and ends
on refresh, expiry, cancellation, epoch change, logout or revocation. Expired
encrypted receipts/challenges are scrubbed every minute; terminal metadata and
command/request tombstones remain to prevent late retries from recreating work.

OAuth `invalid_grant` descriptions are exact codes:
`invalid_request`, `invalid_proof`, `invalid_scope`, `invite_unavailable`,
`invite_expired`, `invite_used`, `invite_cancelled`, `user_disabled`,
`session_revoked`, `recovery_expired`. Unsupported storage/transaction failures
return 503 `temporarily_unavailable`, with no committed claim/session.

## Qualification

Build `deploy/keycloak/Dockerfile` (Maven/JDK21, pinned Keycloak26.8.1; three
JUnit tests). Then:

```sh
python3 scripts/qr-identity-qualification.py --image <built-keycloak-image>
NEPHOS_TEST_IDENTITY_IMAGE=<built-keycloak-image> python3 scripts/identity-production-smoke.py
```

Python QR helper requires `cryptography` (also used by Authlib). It creates
uniquely named private disposable Docker/PostgreSQL resources, never production
fixtures, and cleans them. It qualifies real issuance/replay, signed concurrent
claim, cold restart/lost-response recovery, expiry/cancel, standard refresh
issuer, independent revoke, disable/reenable, transaction rollback after session
writes, and raw-key rotation against claimed/unclaimed invitations. The native qualification
runner separately tests the real trusted-HTTPS/Keychain/gallery path.
