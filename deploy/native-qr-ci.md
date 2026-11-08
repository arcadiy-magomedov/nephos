# Real-service native QR CI

`scripts/native-qr-ci.py` is a qualification fixture, not a production deployment.
It requires a dedicated macOS runner and disposable simulator. There are no Docker,
remote tunnel, bearer injection, alternate authentication, or TLS-bypass paths.

## Workflow contract

The Linux backend job builds the provider from the same checkout. Select Java 21
first (`actions/setup-java`, `distribution: temurin`, `java-version: '21'`); Maven
is available on the hosted Ubuntu runner.

```sh
mvn -B -q -f deploy/keycloak/pin-provider/pom.xml package
# Upload only deploy/keycloak/pin-provider/target/nephos-keycloak-pin-provider.jar.
```

The `macos-26` native job needs Python 3.12 (`actions/setup-python`; Pillow 13
requires Python 3.11+) and `actions/setup-dotnet` with the SDK in `global.json`,
the provider artifact from that successful backend job, and these dependencies:

```sh
brew install openjdk@21 postgresql@17 caddy openssl@3
export JAVA_HOME="$(brew --prefix openjdk@21)/libexec/openjdk.jdk/Contents/Home"
export PATH="$JAVA_HOME/bin:$(brew --prefix postgresql@17)/bin:$(brew --prefix openssl@3)/bin:$PATH"
mkdir -p artifacts/native-qr-input
python3 -m venv artifacts/native-qr-input/venv
artifacts/native-qr-input/venv/bin/pip install \
  -r scripts/native-qr-ci-requirements.txt -r scripts/qr-identity-requirements.txt
curl --fail --location --retry 3 \
  https://github.com/keycloak/keycloak/releases/download/26.8.1/keycloak-26.8.1.tar.gz \
  --output artifacts/native-qr-input/keycloak-26.8.1.tar.gz
echo '4e2740b181faa2ea623a1c2ecf00855935311e546046e2f857615a47ed24cbe8  artifacts/native-qr-input/keycloak-26.8.1.tar.gz' \
  | shasum -a 256 --check
tar -xzf artifacts/native-qr-input/keycloak-26.8.1.tar.gz -C artifacts/native-qr-input
```

Use the existing native job's selected available iOS runtime and create a **new**
simulator, rather than resetting an existing developer simulator. Keep its UUID
in a step output/environment variable. Invoke:

```sh
SIMULATOR_UUID="$(xcrun simctl create Nephos-QR-CI \
  com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro "$IOS_RUNTIME")"
artifacts/native-qr-input/venv/bin/python scripts/native-qr-ci.py \
  --simulator "$SIMULATOR_UUID" \
  --keycloak-dist artifacts/native-qr-input/keycloak-26.8.1 \
  --provider-jar artifacts/native-qr-input/nephos-keycloak-pin-provider.jar
```

The fixture requires the checked-in `nephos.qr.dpop.required=true` policy and
advertised `persistentLogin.refreshBinding=dpop`; it never silently enables a
test-only configuration or downgrades a new sign-in. Existing saved legacy
credentials remain a separate compatibility case, not bearer-authorized migration.
The native CI job first runs `scripts/dpop-identity-qualification.py
--check-lifetime-blockers` against real services, including existing-realm upgrade,
explicit refresh expiry, the 180-day lifetime, and 181-day persisted-session aging.
Neither fixture changes a live deployment or qualifies physical Secure Enclave behavior.

The workflow's `if: always()` cleanup must shutdown/delete this simulator (also
removes its private CA trust) and remove `artifacts/native-qr-ci` and
`artifacts/native-qr-input`.
Do **not** upload either directory, raw service logs, invitations, tokens,
environment dumps, native real-service screenshots, or real-service result
bundles. Artifact upload steps must use explicit safe filenames rather than
recursively uploading `ios/.logs` or the workspace. Service diagnostics deliberately
report stage/status, not raw child output, even on failure.
The default native subprocess timeout is 20 minutes; allow at least 35 minutes
for the job including dependency installation, service startup and compilation.

## Topology and assertions

The fixture reserves random loopback ports and creates owner-only fresh directories.
It starts its own PostgreSQL cluster with SCRAM loopback authentication, disables
Unix sockets (deep checkout paths exceed macOS socket limits), reuses
`deploy/postgres/init.sql`, and executes actual Library migrations.
It copies the pinned Keycloak JVM distribution and provider into private storage,
builds and starts Keycloak in **production** mode, imports the canonical mobile realm
plus the private introspection client, and starts the actual .NET Library API.

Caddy serves a short-lived OpenSSL certificate for `localhost`/`127.0.0.1`, signed
by a fresh private CA; `simctl keychain add-root-cert` trusts that CA only in the
dedicated simulator. The HTTPS origin is `https://127.0.0.1:<random-port>`.
`/v1/*` goes to Library, `/realms/nephos/*` and `/resources/*` to Keycloak.
The fixture verifies HTTPS config and discovery, issuer, chunk size and provider
origin agree before issuing an invitation.

Keycloak's dynamic backchannel exposes private HTTP metadata/JWKS to Library.
Library runs with the same Development/private metadata arrangement as the canonical
compose deployment, but validates the canonical **HTTPS issuer**, real RS256
signatures, audience, expiry and live Keycloak introspection. Host TLS validation is
not bypassed and the host keychain is not modified.

A known disposable identity is provisioned/enabled through the real private
provider, a migrated Library principal/member is seeded through its owner role,
and the real invitation response becomes a private QR PNG. No end-user password
grant or test token is used. The native `ios/qr_qualification.py --qr-image` hook
must decode the PNG, persist a P-256/request journal, exchange the invitation with
the real Keycloak provider, recover a deliberately lost response, atomically commit
Keychain credentials, verify access through the actual authorized Library API,
show the minimal signed-in state, and cold restore with an expired access token.
It also discards a successful bound refresh response, relaunches with the last
durable credential, checks preserved binding, performs DPoP-authenticated RFC7009
revocation, and verifies that the saved revoked session cannot restore.
Its real-service test must not skip when the image argument is supplied.

Child processes run in fixture-owned process groups. Every bounded failure and
SIGINT/SIGTERM terminates only those groups, waits, escalates when necessary, and
removes fresh data, private keys and service logs. Missing dependencies, wrong
Keycloak version/provider, startup failures and native failures are explicit errors.
