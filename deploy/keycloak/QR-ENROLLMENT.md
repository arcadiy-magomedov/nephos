# Production QR enrollment (Keycloak 26.8.1)

The existing provider exposes private identity operations and a normal OAuth
grant, not another token issuer. Existing PIN and browser passkeys remain
compatible. New QR refresh credentials are device-bound; offline sessions use
the explicit 180-day inactivity policy described below.

## Persistent login and DPoP feasibility

**Status: DPoP required for new QR sign-ins, with a 180-day inactivity policy.**
The provider can bind new QR offline refresh credentials to the enrollment key,
preserve binding during receipt recovery/refresh, and leave access tokens Bearer.
The checked-in realm config sets offline-session inactivity to 180 days
(`15552000` seconds), with the absolute offline-session maximum disabled. No live
realm has been changed. Native Simulator qualification covers initial enrollment,
lost enrollment/refresh responses, cold restoration, binding consistency,
authenticated Library access, and RFC7009 revocation. Physical-device Secure
Enclave behavior and live-deployment acceptance remain unqualified. Real-service
checks cover the 180-day lifetime, 181-day persisted-session aging/cleanup,
existing-realm upgrade, and two-node replay/refresh/revocation behavior.

**Critical 26.8.1 lifetime finding:** `offlineSessionIdleTimeout: 0` is **not**
unlimited. [`SessionExpirationUtils.getOfflineSessionIdleTimeout`](https://github.com/keycloak/keycloak/blob/26.8.1/server-spi-private/src/main/java/org/keycloak/models/utils/SessionExpirationUtils.java)
substitutes
`Constants.DEFAULT_OFFLINE_SESSION_IDLE_TIMEOUT` (30 days). The default refresh
provider ([`DefaultRefreshTokenProvider`](https://github.com/keycloak/keycloak/blob/26.8.1/services/src/main/java/org/keycloak/protocol/oidc/refresh/DefaultRefreshTokenProvider.java))
emits a finite `exp`, and session validation and cleanup also enforce inactivity.
The repository now explicitly configures a 180-day idle timeout rather than
relying on the 30-day default. Successful refresh extends the offline-session
idle deadline and issues a refresh credential with the configured finite
lifetime. If the device cannot successfully renew for 180 days, it must be
enrolled again. iOS background scheduling is opportunistic and cannot guarantee
renewal during prolonged inactivity; foreground/normal-use renewal is the
reliability path.

The shipped `nephos.qr.dpop.required` client attribute is **true**.
The native fixture verifies this shipped setting instead of silently enabling it.
Existing deployments receive the profile/policy and timeout through `admin-init`;
realm import alone does not update an existing realm. This repository change
does not modify a running deployment.

The version-pinned upstream evidence is:

- [26.8.1 DPoP guide](https://github.com/keycloak/keycloak/blob/26.8.1/docs/guides/securing-apps/dpop.adoc):
  public-client refresh binding and `dpop-bind-enforcer` refresh-token-only mode.
- [Feature profile](https://github.com/keycloak/keycloak/blob/26.8.1/common/src/main/java/org/keycloak/common/Profile.java):
  DPoP is a default feature, not a preview-only prerequisite in this release.
- [Token endpoint](https://github.com/keycloak/keycloak/blob/26.8.1/services/src/main/java/org/keycloak/protocol/oidc/endpoints/TokenEndpoint.java):
  validates supplied DPoP proofs before dispatching extension grants, including QR.
- [Policy executor](https://github.com/keycloak/keycloak/blob/26.8.1/services/src/main/java/org/keycloak/services/clientpolicy/executor/DPoPBindEnforcerExecutor.java)
  and [TokenManager](https://github.com/keycloak/keycloak/blob/26.8.1/services/src/main/java/org/keycloak/protocol/oidc/TokenManager.java):
  support `allow-only-refresh-token-binding` and verify the refresh token's
  public-key thumbprint against the submitted proof.

This is not a configuration-only change. Integration boundaries:

1. **Native key and proof lifecycle.** Persist an account/server-bound P-256 key
   before issuance; prefer Secure Enclave protection on supported devices.
   Generate standards-compliant ES256 DPoP JWTs, with public JWK, unique `jti`,
   `htm`, canonical `htu`, `iat`, and server nonce when requested. An API proof
   additionally needs `ath` if full access-token DPoP is later selected.
   QR's existing canonical-text/DER signature is not this JWT proof format.
2. **Initial QR issuance and receipt recovery.** `QrGrant` now calls the upstream
   refresh-only enforcer **before** `createTokenResponse`, not in a response hook
   after tokens exist. It requires the validated DPoP JWK thumbprint to equal the
   RFC7638 thumbprint of the submitted, challenge-verified P-256 enrollment point.
   The durable encrypted receipt metadata includes that thumbprint. Recovery
   needs a fresh QR challenge and DPoP proof from the same key; swapping either
   key cannot replace the original session binding.
3. **Silent renewal, logout, and errors.** Send fresh proofs for refresh and
   required logout/revocation requests. Handle nonce negotiation without logging
   out. Keycloak can report missing/mismatched refresh proof binding as
   `invalid_grant`; the client must not blindly treat that string as confirmed
   administrative revocation. Test last-durable-token recovery with the actual
   180-day offline-session/rotation policy; DPoP itself does not solve lost
   replacement tokens or authorize arbitrary key replacement. Recovery remains
   bounded by the configured inactivity lifetime.
4. **API scope.** Refresh-only binding can keep current bearer API transport,
   JWT validation, resource authorization, and live introspection. Full DPoP
   additionally requires changes to `Nephos.ServiceDefaults` and all relevant
   resource boundaries: `Authorization: DPoP`, proof signature and `cnf.jkt`,
   `ath`, method/URI/time/nonce validation, replay protection across replicas,
   and rejection of bearer downgrade. Introspection alone does not validate
   these request proofs. Canonical external URLs and trusted-proxy handling
   must agree across Caddy, Compose, and multi-replica deployments.
5. **Compatibility and qualification.** Existing bearer sessions and the legacy
   PIN grant share the client contract; plan and test their migration before
   requiring bound tokens. Do not silently relax binding or force all users to
   sign in again as an incidental configuration update. Run C03's real-service
   and physical-device acceptance cases before declaring the requirement met.

The protocol references are [RFC 9449](https://www.rfc-editor.org/rfc/rfc9449.html)
and [RFC 9700 section 4.14.2](https://www.rfc-editor.org/rfc/rfc9700.html#section-4.14.2).
The latter permits sender-constrained refresh tokens instead of mandatory
single-use refresh-token rotation for public clients.

### Gated wire contract and compatibility

The QR JSON remains exactly `v/origin/inviteId/secret`; challenge and grant form
fields remain unchanged. The config response adds:

```json
{
  "persistentLogin": {
    "version": 1,
    "refreshBinding": "dpop",
    "dpopAlgorithm": "ES256",
    "dpopKey": "enrollment",
    "accessTokenType": "Bearer",
    "refreshReuse": "session-lifetime",
    "legacySessions": "unbound-no-rebind"
  }
}
```

`refreshBinding` is `legacy-bearer` with the rollout gate off. `session-lifetime`
is intentional: do not advertise `until-revoked` on 26.8.1. No existing client
must interpret the capability as authorization to replace an existing key.

With the gate on, initial QR exchange, QR receipt recovery, and each bound-token
refresh send `DPoP: <JWT>` with protected header
`{"typ":"dpop+jwt","alg":"ES256","jwk":{"kty":"EC","crv":"P-256","x":"...","y":"..."}}`.
Coordinates are 32-byte, unpadded base64url. Claims are fresh random `jti`,
integer UTC `iat`, `htm:"POST"` and canonical external HTTPS `htu` matching the
token endpoint, without query/fragment. ES256 JWT signatures are raw 64-byte
`r||s`; QR challenge signatures stay DER. No `ath` is needed for token or
revocation requests. Never send the private JWK fields. Keycloak validates the
proof once before grant dispatch; the provider reuses that validated result.
Pinned validation accepts a 10-second proof lifetime plus 15-second clock skew.
Generate a new proof on **every** attempt, including transport/nonce retries.

Successful token responses have `token_type: Bearer`, an access token without
`cnf`, and an offline refresh token with `cnf.jkt` matching the device key.
Persist and validate that binding, including replacements and recovered receipts;
never accept a bearer-only replacement for a known bound session. API requests
continue `Authorization: Bearer`; the .NET validators and live introspection are
unchanged. Rotation remains explicitly disabled (`revokeRefreshToken:false`):
old durable refresh tokens work with fresh same-key proofs **until their actual
expiry/session lifetime**, configured as 180 days of inactivity, including after
newer responses and a server restart.

#### Refresh JWT claims and native trust boundary

The real 26.8.1 fixture verifies this contract on initial QR issuance and subsequent
renewal:

| Refresh field | Pinned contract |
|---|---|
| Protected-header `alg` | **`HS512`**, Keycloak's internal-token signing algorithm—not the RS256 access/ID-token algorithm |
| `iss` | Present; canonical realm issuer (`<origin>/realms/nephos`) |
| `sub` | Present; same account subject as the verified ID/access tokens |
| `azp` | Present; `nephos-ios`, the client for which the credential was issued |
| `aud` | Present; the **issuer URL**, not `nephos-ios` or `nephos-api`; accept the JWT string/singleton-array representation |
| Payload `typ` | **`Offline`**, case-sensitive; distinct from the JWT protected-header `typ` |
| `iat` | Present; integer NumericDate in UTC epoch seconds, renewed for each newly issued credential |
| `exp` | Present and future; `iat + 15552000` seconds under the checked-in 180-day realm policy |
| `cnf.jkt` | Present for bound sessions; RFC7638 SHA-256 thumbprint of the same P-256 enrollment public key |

[`RefreshToken`](https://github.com/keycloak/keycloak/blob/26.8.1/core/src/main/java/org/keycloak/representations/RefreshToken.java)
copies issuer/subject/authorized party from the access token, sets the refresh
audience to the issuer, and declares `TokenCategory.INTERNAL`.
[`DefaultTokenManager`](https://github.com/keycloak/keycloak/blob/26.8.1/services/src/main/java/org/keycloak/jose/jws/DefaultTokenManager.java)
uses `Constants.INTERNAL_SIGNATURE_ALGORITHM` (`HS512`) for that category.
The offline refresh provider sets payload `typ=Offline` and its lifetime.

**A native public client cannot verify this refresh-token HMAC through JWKS.**
Never expose the realm HMAC signing secret, change realm signing algorithms to
satisfy a client verifier, or treat a matching decoded `alg`/claim set as signature
verification. Treat the refresh credential as opaque authority usable only by
Keycloak. Accept it only from the expected canonical token endpoint (including
QR receipt recovery) over authenticated, certificate-validated, **nonredirecting
HTTPS**. The client may decode the pinned JWT format for response-consistency and
binding checks against its saved key, expected issuer/client and verified account;
these checks rely on the authenticated response channel, **not public verification
of the refresh signature**. Reject inconsistent metadata without silently
downgrading a bound session.

Continue independently verifying access/ID-token asymmetric signatures with the
trusted issuer's JWKS and their applicable issuer/audience/lifetime/subject/nonce
rules. Do not feed refresh tokens through that shared RS256 verifier or apply the
ID-token client-audience rule to refresh `aud`. Never establish account identity or
authorization from a separately supplied or merely decoded refresh JWT. Keycloak
verifies its HMAC, session status and DPoP binding on redemption. Any future
non-expiring/opaque format needs an explicitly qualified contract change; do not
silently assume `exp` is absent on today's server.

Remote sign-out for bound sessions uses the discovered RFC7009
`revocation_endpoint` (`.../protocol/openid-connect/revoke`), POST form
`client_id=nephos-ios&token=<refresh-token>&token_type_hint=refresh_token`, and a
fresh DPoP proof whose `htu` is the **revocation** endpoint. Success is HTTP 200.
The built-in legacy `/logout` refresh-token path does not populate the validated
DPoP request attribute in this release; do not use it for bound sessions.
Local sign-out, unavailable Keychain, and failed/offline remote revocation remain
separate outcomes. Keep the stable key as long as any durable bound credential or
pending enrollment needs it; do not rotate it on refresh/relaunch.

The `nephos-persistent-login` profile/policy must remain installed for all bound
sessions, even if the new-enrollment gate is turned off. It delegates to the
upstream enforcer only for already-bound refresh/revocation tokens and never
enables full access-token DPoP. Do not apply a global stock `dpop-bind-enforcer`
policy to this shared client: that would disrupt legacy sessions and allow
bearer-authorized key adoption. Existing realm imports are **not** automatically
updated on restart. The idempotent `scripts/admin-bootstrap.py` (`admin-init`)
merges the named profile/policy without deleting unrelated custom policies,
sets the 180-day realm policy, removes mobile client timeout overrides, and
enables new-enrollment binding. Existing users and sessions are preserved.
The provider rejects incompatible timeout, rotation, or access-token binding
settings rather than issuing unusable credentials.

Existing QR/PIN/browser bearer sessions continue without DPoP and are explicitly
**not sender constrained**. Existing legacy QR receipts can still be recovered
without changing their binding. Sending a DPoP proof with an unbound refresh
token is rejected as `legacy_session_unbound`, not silently rebound. A bound
session never retries without proof. Migration to protection requires a new
administrator-authorized enrollment, explicitly chosen for that device; no
mass logout or bearer-token-only key adoption is implemented. Automatic
registered-key migration is deferred, not claimed.

### Error and retry contract

Preserve durable credentials on proof, clock, configuration, network, rate-limit,
TLS, identity-outage, and unknown errors. Do not classify solely on HTTP status
or `invalid_grant`.

| Response | Meaning and native behavior |
|---|---|
| `400 invalid_dpop_proof`, description `dpop_proof_required` / `dpop_key_mismatch` | Missing/wrong stable proof key; retain session, recover key/configuration, never retry bearer-only |
| `400 invalid_dpop_proof`, `legacy_session_unbound` | This is an explicitly legacy credential; no automatic binding/migration. Do not use this error to downgrade a locally known bound session |
| `400 invalid_dpop_proof`, `persistent_login_not_enabled` | New DPoP enrollment attempted against a gated-off server; configuration/rollout issue |
| `400 invalid_request` from Keycloak proof validation | Malformed/replayed/stale proof or wrong method/target; correct clock/URL and retry with a new proof, retain credentials |
| `503 temporarily_unavailable`, `persistent_login_configuration` | Rotation, timeout override, full-access-DPoP or feature configuration is incompatible; repair server configuration, retain credentials |
| `400 invalid_grant` with `Refresh token expired`, `Offline user session not found`, `Offline session not active`, `Session not active`, `Client session not active`, `Session doesn't have required client`, `User disabled`, or `Offline session invalid because offline access not granted anymore` | Verified credential/session/account authority no longer usable; requires enrollment, not proof retry. Expiry is intentional under the 180-day policy, **not necessarily administrator revocation** |
| Other `invalid_grant` (including `DPoP proof is missing`, binding mismatch, token expiry/signature/client/issuer errors) | Do not wipe session indiscriminately; retain and surface recovery/configuration failure. A known permanently lost key is a separate local terminal condition |
| Revocation `invalid_dpop_proof` / `invalid_token` | Remote sign-out was not confirmed; preserve distinction from local sign-out and retry with correct key/proof when appropriate |

This pinned server does not issue/require DPoP nonces. Native code should preserve
the session and bound retries if a future qualified server sends `use_dpop_nonce`
with `DPoP-Nonce`; nonce issuance/replica coordination are not qualified here.

### Executable server qualification

Build the actual provider with JDK21 and Maven, then run:

```sh
mvn -q -f deploy/keycloak/pin-provider/pom.xml test package
python3 scripts/dpop-identity-qualification.py \
  --keycloak-dist /path/to/keycloak-26.8.1 \
  --provider-jar deploy/keycloak/pin-provider/target/nephos-keycloak-pin-provider.jar
  # Add --check-lifetime-blockers to exercise 181-day persisted-session cleanup.
```

Requirements: Python `cryptography` (the existing
`scripts/qr-identity-requirements.txt` pin), JDK21/25, PostgreSQL binaries,
OpenSSL3, Caddy and .NET10. No Simulator, host trust changes, Docker, live realm
credentials, or global installation are needed. Reuses the native fixture's
disposable loopback PostgreSQL, actual .NET service, Keycloak production-mode
startup and private HTTPS CA. Secrets/data/owned processes are removed afterward.

Coverage: initial binding versus Bearer access; same-key receipt recovery and
restart; missing/wrong/replayed/stale/method/target proof rejection; recovery key
swap rejection; original refresh reuse after a lost response, 27-second proof
window and restart; live introspection; legacy no-rebind; unsafe rotation guard;
device revocation, RFC7009 sign-out and account disablement. The runner also
asserts the 180-day token lifetime, rejects incompatible timeouts, qualifies an
idempotent existing-realm upgrade without losing legacy/bound sessions, and
checks explicit credential expiry. The optional aging check tests session
validation and scheduled cleanup at 181 days without changing the host clock.
`scripts/qr-identity-qualification.py` uses two real Keycloak nodes to verify
cross-node receipt recovery, DPoP replay rejection, renewal and revocation,
concurrent claim, and cold restart. Physical-device storage, future nonce
issuance, and a particular live deployment remain outside these fixtures.
Offline periods longer than 180 days intentionally require a new QR enrollment.

### Historical investigation of indefinite lifetime (2026-11-08)

This investigation addressed the earlier requirement for indefinite offline
validity. The user has since selected a finite 180-day inactivity policy, so
the provider-extension options below are no longer active blockers. The source
findings remain relevant if the product later requires sessions to survive
longer than the configured inactivity window.

**Conclusion:** no narrow, supported lifetime hook was found that satisfies token
expiry, session validity/loading, persisted cleanup **and existing introspection**
for `nephos-ios`. Do not enable production or issue a supposedly indefinite token
by removing only its `exp`.

Configuration was checked against pinned **26.8.1** and latest released
**[26.8.2](https://github.com/keycloak/keycloak/releases/tag/26.8.2)**
(released 2026-11-05). `SessionExpirationUtils` is identical between these tags.
The 26.8.2 default refresh-provider changes concern revocation cleanup, not
lifetime. [Official 26.8.2 timeout documentation](https://github.com/keycloak/keycloak/blob/26.8.2/docs/documentation/server_admin/topics/sessions/timeouts.adoc)
explicitly says disabling Offline Session Max removes the **lifespan** limit,
not the **idle** limit. Neither zero nor negative realm/client idle values select
an infinite-lifetime policy. Cache lifetime overrides affect caching, not durable
authority. An upgrade to 26.8.2 alone therefore does not solve this requirement;
no distribution was upgraded or patched during this investigation.

The actual extension boundaries are:

| Boundary | Available extension | Why it does not solve the whole requirement |
|---|---|---|
| Signed refresh credential lifetime | [`RefreshTokenProvider`](https://github.com/keycloak/keycloak/blob/26.8.1/services/src/main/java/org/keycloak/protocol/oidc/refresh/RefreshTokenProvider.java), selected by factory order and `supports(...)` | A provider could narrowly select bound `nephos-ios` offline sessions and generate a token without expiration while retaining Keycloak signing and DPoP verification. This alone leaves all session expiry paths intact. [`RefreshTokenSpi`](https://github.com/keycloak/keycloak/blob/26.8.1/services/src/main/java/org/keycloak/protocol/oidc/refresh/RefreshTokenSpi.java) explicitly reports `isInternal() == true`; provider loading is extensible, but that is not a stable lifetime-policy contract. |
| Renewal session validation | [`DefaultRefreshTokenProvider.validateToken`](https://github.com/keycloak/keycloak/blob/26.8.1/services/src/main/java/org/keycloak/protocol/oidc/refresh/DefaultRefreshTokenProvider.java) is protected and overridable | The normal path calls [`TokenManager.validateToken`](https://github.com/keycloak/keycloak/blob/26.8.1/services/src/main/java/org/keycloak/protocol/oidc/TokenManager.java), including static `AuthenticationManager.isSessionValid/isClientSessionValid`. No per-session lifetime-policy callback exists there. Replacing the validator must retain every user/client/scope/consent/not-before/session-start/revocation check; an override does not repair session loading or cleanup. |
| Cold loading, caches and session enumeration | Internal [`UserSessionProvider`](https://github.com/keycloak/keycloak/blob/26.8.1/server-spi/src/main/java/org/keycloak/models/UserSessionProvider.java) replacement | [`PersistentUserSessionProvider.wrapPersistentEntity`](https://github.com/keycloak/keycloak/blob/26.8.1/model/infinispan/src/main/java/org/keycloak/models/sessions/infinispan/PersistentUserSessionProvider.java) refuses aged entities; private expiry predicates and cache timeout functions use the finite policy. The JPA persister also filters session list/load queries by `lastSessionRefresh`. Retaining database rows is insufficient. A provider replacement is selected server-wide, not a narrow client-scoped expiry callback. |
| Durable cleanup | Internal [`UserSessionPersisterProvider.removeExpired(realm)`](https://github.com/keycloak/keycloak/blob/26.8.1/model/storage-private/src/main/java/org/keycloak/models/session/UserSessionPersisterProvider.java) replacement | [`JpaUserSessionPersisterProvider`](https://github.com/keycloak/keycloak/blob/26.8.1/model/jpa/src/main/java/org/keycloak/models/jpa/session/JpaUserSessionPersisterProvider.java) invokes package-private/final [`UserSessionExpirationLogic`](https://github.com/keycloak/keycloak/blob/26.8.1/model/jpa/src/main/java/org/keycloak/models/jpa/session/UserSessionExpirationLogic.java). Its realm-wide age queries have no `nephos-ios`/session-note exemption or veto callback and remove user/client rows. General JPA `ExpirationAction` callbacks do not replace this independently scheduled user-session cleanup. Disabling cleanup or recreating removed sessions is not acceptable. |
| Bearer API live introspection | Internal [`TokenIntrospectionProvider`](https://github.com/keycloak/keycloak/blob/26.8.1/server-spi-private/src/main/java/org/keycloak/protocol/oidc/TokenIntrospectionSpi.java) replacement is possible | Standard [`AccessTokenIntrospectionProvider`](https://github.com/keycloak/keycloak/blob/26.8.1/services/src/main/java/org/keycloak/protocol/oidc/AccessTokenIntrospectionProvider.java) calls [`UserSessionUtil`](https://github.com/keycloak/keycloak/blob/26.8.1/services/src/main/java/org/keycloak/services/util/UserSessionUtil.java), which independently applies session validity. Bypassing expiry only in refresh would still leave new API tokens inactive. Adding token verifier checks cannot remove existing session checks. |

The other built-in refresh provider,
[`OID4VCIRefreshTokenProvider`](https://github.com/keycloak/keycloak/blob/26.8.1/services/src/main/java/org/keycloak/protocol/oid4vc/refresh/OID4VCIRefreshTokenProvider.java),
is not an offline-device-session solution: it explicitly rejects `offline_access`,
requires verifiable-credential scopes/authorization details, uses credential-based
authority and transient sessions, and does not support initial QR grants.
Repurposing it would change the authentication/authority model, not configure
existing persistent sessions.

**Concrete options requiring approval; none implemented:**

1. **Preferred: an upstream-supported lifetime policy/version.** Propose explicit
   no-idle/no-absolute-expiry authority for selected offline client sessions, with
   a durable policy marker that all issuance, validation, load/list/cache and
   cleanup paths honor consistently. For Nephos, admit only newly authorized
   DPoP-bound QR sessions, not legacy bearer tokens. Keycloak remains the token
   issuer and sole revocable session authority; existing short-lived Bearer API
   validation/introspection stays intact. The policy must preserve deletion,
   disablement, not-before, consent and device revocation and must never
   resurrect expired/revoked sessions. Acceptance requires a released supporting
   version, or separate approval for maintaining a narrowly reviewed upstream
   patch; a local patch is **not** authorized by this investigation.
2. **Larger in-provider implementation, not a narrow supported hook.** A
   version-pinned coordinated replacement of refresh validation, user-session
   loading/cache behavior, JPA expiry/list handling and introspection could be
   engineered behind selective immutable session metadata while delegating
   unrelated clients/realms to default behavior. This is substantial ownership of
   internal Keycloak security behavior and cleanup SQL, with upgrade/cluster/
   revocation-race risk—not the small token-provider extension initially sought.
   Require a separate design, maintenance commitment, approval and full
   acceptance matrix before coding. Do not equate service-loader support with
   upstream support for these new lifetime semantics.

A separate device-authority/credential ledger, synthetic activity timestamps,
keepalives, disabled cleanup, session resurrection or an expiry-bypassing
introspection shortcut are **not approved alternatives**. The chosen policy is
an explicit finite timeout, not a way to simulate indefinite validity.

**Reproducible runtime evidence:** `--check-lifetime-blockers` now ages only the
persisted offline user-session timestamps for two task-owned devices by 181
days; the host clock, signed token timestamps and online sessions remain
unchanged. The updated check qualifies the selected 180-day policy. After cold restart:

- The first still-fresh signed refresh token fails because its stored session
  is aged, independently of JWT expiry; normal introspection reports inactive.
- The second session is never requested or admin-read. Keycloak's normal
  scheduled cleaner deletes its offline user **and client** rows. The fixture
  uses the normal `session-expiration-period=60` cleanup scheduling option.
- An unrelated, non-aged bound device keeps refreshing successfully.

This real PostgreSQL/26.8.1 test passes and demonstrates separate load/validation
and persisted-cleanup blockers. It does **not** claim a lifetime solution.
No replacement provider, distribution patch, global clock change, new authority,
or production configuration change was made.

Native integration verifies the shipped DPoP contract with
`scripts/native-qr-ci.py`; see
[native fixture usage](../native-qr-ci.md). New native QR sign-ins must require
advertised `refreshBinding=dpop` rather than silently accepting a legacy-bearer
server. Saved legacy sessions remain separately usable without automatic rebinding.

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
grantType:"urn:nephos:params:oauth:grant-type:qr",persistentLogin:{...}}`;
the gated capability object is specified above.

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
