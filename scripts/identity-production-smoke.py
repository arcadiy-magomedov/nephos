#!/usr/bin/env python3
"""Boot production-mode Keycloak against a disposable isolated PostgreSQL instance."""

import base64
import json
import os
import secrets
import socket
import subprocess
import time
import urllib.parse
import uuid

import smoke

prefix = "nephos-identity-smoke-" + uuid.uuid4().hex
database, identity, network = prefix + "-db", prefix + "-identity", prefix + "-network"
password = secrets.token_hex(24)
identity_admin_service_key = secrets.token_hex(32)
pin_pepper = secrets.token_hex(32)
introspection_secret = secrets.token_hex(32)
environment = {
    **os.environ,
    "POSTGRES_PASSWORD": password,
    "KC_DB_PASSWORD": password,
    "KC_BOOTSTRAP_ADMIN_PASSWORD": password,
    "IDENTITY_ADMIN_SERVICE_KEY": identity_admin_service_key,
    "NEPHOS_PIN_PEPPER": pin_pepper,
    "API_INTROSPECTION_CLIENT_SECRET": introspection_secret,
    "NEPHOS_PUBLIC_ORIGIN": "https://photos.example.test",
    "NEPHOS_QR_DELIVERY_KEY": base64.b64encode(secrets.token_bytes(32)).decode(),
}
containers = []


def docker(*args):
    return subprocess.run(
        ["docker", *args], env=environment, cwd=smoke.ROOT, check=True, capture_output=True, text=True
    ).stdout.strip()


compose = ["compose", "--env-file", ".env"]
if (smoke.ROOT / ".env.faces").exists() and (smoke.ROOT / "artifacts/lan/compose.yaml").exists():
    compose += [
        "--env-file",
        ".env.faces",
        "-f",
        "compose.yaml",
        "-f",
        "compose.faces.yaml",
        "-f",
        "artifacts/lan/compose.yaml",
    ]
configuration = json.loads(docker(*compose, "config", "--format", "json"))
postgres_image = configuration["services"]["postgres"]["image"]
identity_image = os.environ.get("NEPHOS_TEST_IDENTITY_IMAGE", configuration["services"]["keycloak"]["image"])
with socket.socket() as reservation:
    reservation.bind(("127.0.0.1", 0))
    port = reservation.getsockname()[1]
docker("network", "create", network)
try:
    docker(
        "run",
        "-d",
        "--name",
        database,
        "--network",
        network,
        "--memory",
        "256m",
        "--tmpfs",
        "/var/lib/postgresql:rw",
        "-e",
        "POSTGRES_PASSWORD",
        "-e",
        "POSTGRES_DB=keycloak",
        "-e",
        "POSTGRES_USER=keycloak",
        postgres_image,
    )
    containers.append(database)

    def database_ready():
        return (
            subprocess.run(["docker", "exec", database, "pg_isready", "-U", "keycloak"], capture_output=True).returncode
            == 0
        )

    smoke.wait("isolated identity database ready", database_ready)
    docker(
        "run",
        "-d",
        "--name",
        identity,
        "--network",
        network,
        "--memory",
        "768m",
        "-p",
        f"127.0.0.1:{port}:8080",
        "-e",
        "KC_DB=postgres",
        "-e",
        f"KC_DB_URL=jdbc:postgresql://{database}:5432/keycloak",
        "-e",
        "KC_DB_USERNAME=keycloak",
        "-e",
        "KC_DB_PASSWORD",
        "-e",
        "KC_BOOTSTRAP_ADMIN_USERNAME=admin",
        "-e",
        "KC_BOOTSTRAP_ADMIN_PASSWORD",
        "-e",
        "IDENTITY_ADMIN_SERVICE_KEY",
        "-e",
        "NEPHOS_PIN_PEPPER",
        "-e",
        "NEPHOS_PUBLIC_ORIGIN",
        "-e",
        "NEPHOS_QR_DELIVERY_KEY",
        "-e",
        "KC_HTTP_ENABLED=true",
        "-e",
        "KC_PROXY_HEADERS=xforwarded",
        "-e",
        "KC_HOSTNAME=https://photos.example.test",
        "-e",
        f"KC_HOSTNAME_ADMIN=http://localhost:{port}",
        "-e",
        "KC_HOSTNAME_BACKCHANNEL_DYNAMIC=true",
        "-v",
        str(smoke.ROOT / "deploy/keycloak/nephos-realm.json") + ":/opt/keycloak/data/import/nephos-realm.json:ro",
        identity_image,
        "start",
        "--import-realm",
    )
    containers.append(identity)
    discovery = smoke.wait(
        "production-mode identity serves the imported closed realm",
        lambda: smoke.request(f"http://localhost:{port}/realms/nephos/.well-known/openid-configuration"),
        timeout=150,
    )
    assert discovery["issuer"] == "https://photos.example.test/realms/nephos"
    forwarded = smoke.request(
        f"http://localhost:{port}/realms/nephos/.well-known/openid-configuration",
        headers={"X-Forwarded-Proto": "https", "X-Forwarded-Host": "photos.example.test", "X-Forwarded-Port": "443"},
    )
    assert forwarded["jwks_uri"].startswith("https://photos.example.test/")
    logs = docker("logs", identity)
    assert "Running the server in development mode" not in logs

    def admin_token():
        return smoke.request(
            f"http://localhost:{port}/realms/master/protocol/openid-connect/token",
            data=urllib.parse.urlencode(
                {"client_id": "admin-cli", "grant_type": "password", "username": "admin", "password": password}
            ).encode(),
            headers={"Content-Type": "application/x-www-form-urlencoded"},
        )["access_token"]

    admin = admin_token()
    admin_base = f"http://localhost:{port}/admin/realms/nephos"
    realm = smoke.request(admin_base, token=admin)
    assert realm["offlineSessionIdleTimeout"] == 180 * 24 * 60 * 60
    assert realm["offlineSessionMaxLifespanEnabled"] is False
    username = "pin-smoke-" + uuid.uuid4().hex
    smoke.request(
        admin_base + "/users",
        token=admin,
        method="POST",
        expected=201,
        data={"username": username, "email": username + "@example.test", "enabled": True},
    )
    user = smoke.request(admin_base + "/users?exact=true&username=" + username, token=admin)[0]
    subject = user["id"]
    pin_base = f"http://localhost:{port}/realms/nephos/nephos-admin"
    service_headers = {"X-Nephos-Identity-Service-Key": identity_admin_service_key}
    smoke.request(pin_base + "/pin-requests", expected=401)
    smoke.request(pin_base + "/pin-requests", token=admin, expected=401)
    assert smoke.request(pin_base + "/pin-requests", headers=service_headers) == {"requests": []}

    def request_pin(email, expected=200, **extra):
        request = urllib.request.Request(
            pin_base + "/request-pin",
            method="POST",
            data=json.dumps({"email": email, "clientId": "nephos-ios", **extra}).encode(),
            headers={"Content-Type": "application/json"},
        )
        try:
            response = urllib.request.urlopen(request, timeout=10)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            assert response.status == expected, f"PIN request: expected {expected}, got {response.status}"
            assert response.headers["Cache-Control"] == "no-store"
            if expected == 429:
                assert response.headers["Retry-After"] == "60"
            payload = json.load(response)
        if expected == 200:
            assert set(payload) == {"expiresIn"}, "Public PIN responses must contain only the expiry receipt."
        return payload

    smoke.request(
        pin_base + "/request-pin",
        method="POST",
        data=b'{"email":',
        headers={"Content-Type": "application/json"},
        expected=400,
    )
    smoke.request(
        pin_base + "/request-pin",
        method="POST",
        data=b" " * 1025,
        headers={"Content-Type": "application/json"},
        expected=400,
    )
    assert request_pin(username + "@example.test", 400, clientId="admin-cli")["error"] == "invalid_request"
    for email in ("not-an-email", "a..b@example.test", "a@-example.test"):
        assert request_pin(email, 400)["error"] == "invalid_email"
    assert request_pin("unknown@example.test", 404)["error"] == "account_unavailable"
    disabled_username = "disabled-" + username
    smoke.request(
        admin_base + "/users",
        token=admin,
        method="POST",
        expected=201,
        data={"username": disabled_username, "email": disabled_username + "@example.test", "enabled": False},
    )
    assert request_pin(disabled_username + "@example.test", 404)["error"] == "account_unavailable"
    assert smoke.request(pin_base + "/pin-requests", headers=service_headers) == {"requests": []}
    receipt = request_pin("  " + username.upper() + "@EXAMPLE.TEST  ")
    assert receipt == {"expiresIn": 1800}, receipt
    pending = smoke.request(pin_base + "/pin-requests", headers=service_headers)["requests"]
    assert len(pending) == 1 and pending[0]["email"] == username + "@example.test"
    assert pending[0]["username"] == username and len(pending[0]["pin"]) == 8 and pending[0]["pin"].isdigit()
    issued = {"pin": pending[0]["pin"], "expiresIn": receipt["expiresIn"]}
    repeated = request_pin(username + "@example.test")
    assert set(repeated) == {"expiresIn"} and 1 <= repeated["expiresIn"] <= 1800
    assert smoke.request(pin_base + "/pin-requests", headers=service_headers)["requests"] == pending
    # Ten requests, including malformed/unknown requests and reuse, exhaust the IP budget.
    assert request_pin(username + "@example.test", 429)["error"] == "rate_limited"
    assert request_pin("different-unknown@example.test", 429)["error"] == "rate_limited"
    smoke.request(
        pin_base + "/request-pin",
        method="POST",
        data=b'{"email":',
        headers={"Content-Type": "application/json"},
        expected=429,
    )
    time.sleep(61)
    repeated = request_pin(username + "@example.test")
    assert set(repeated) == {"expiresIn"} and 1 <= repeated["expiresIn"] < 1800
    assert smoke.request(pin_base + "/pin-requests", headers=service_headers)["requests"] == pending
    # Reuse did not renew the issuance cooldown. Revocation permits new issuance now.
    smoke.request(pin_base + f"/users/{subject}/pin", method="DELETE", headers=service_headers, expected=204)
    request_pin(username + "@example.test")
    smoke.request(pin_base + f"/users/{subject}/pin", method="DELETE", headers=service_headers, expected=204)
    assert request_pin(username + "@example.test", 429)["error"] == "rate_limited"
    assert smoke.request(pin_base + "/pin-requests", headers=service_headers) == {"requests": []}
    time.sleep(61)
    receipt = request_pin(username + "@example.test")
    pending = smoke.request(pin_base + "/pin-requests", headers=service_headers)["requests"]
    issued = {"pin": pending[0]["pin"], "expiresIn": receipt["expiresIn"]}
    for _ in range(3):
        repeated = request_pin(username + "@example.test")
        assert set(repeated) == {"expiresIn"} and 1 <= repeated["expiresIn"] <= receipt["expiresIn"]
    assert smoke.request(pin_base + "/pin-requests", headers=service_headers)["requests"] == pending
    smoke.request(
        f"http://localhost:{port}/realms/nephos/nephos-admin/users/{subject}/pin",
        method="POST",
        expected=401,
    )
    token_url = f"http://localhost:{port}/realms/nephos/protocol/openid-connect/token"
    grant = {
        "grant_type": "urn:nephos:params:oauth:grant-type:login-pin",
        "client_id": "nephos-ios",
        "username": username + "@example.test",
        "pin": issued["pin"],
        "nonce": secrets.token_urlsafe(32),
        "scope": "openid profile offline_access",
        "device_id": str(uuid.uuid4()),
        "device_name": "Identity smoke device",
    }
    incorrect_grant = {**grant, "pin": ("0" if issued["pin"][0] != "0" else "1") + issued["pin"][1:]}
    smoke.request(
        token_url,
        data=urllib.parse.urlencode(incorrect_grant).encode(),
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        expected=400,
    )
    token_response = smoke.request(
        token_url,
        data=urllib.parse.urlencode(grant).encode(),
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )
    assert token_response["access_token"] and token_response["id_token"] and token_response["refresh_token"]
    for token_type in ("access_token", "id_token"):
        encoded = token_response[token_type].split(".")[1]
        claims = json.loads(base64.urlsafe_b64decode(encoded + "=" * (-len(encoded) % 4)))
        assert claims["sub"] == subject, f"{token_type} must identify the known library account"
        assert claims.get("iss") == discovery["issuer"], f"{token_type} must use the canonical issuer"
    assert smoke.request(pin_base + "/pin-requests", headers=service_headers) == {"requests": []}
    # Consumed PINs cannot be recovered or reissued through the pending-request path.
    assert request_pin(username + "@example.test", 429)["error"] == "rate_limited"
    smoke.request(
        token_url,
        data=urllib.parse.urlencode(grant).encode(),
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        expected=400,
    )
    time.sleep(61)
    request_pin(username + "@example.test")
    replaced_pin = smoke.request(pin_base + "/pin-requests", headers=service_headers)["requests"][0]["pin"]
    second_pin = smoke.request(
        f"http://localhost:{port}/realms/nephos/nephos-admin/users/{subject}/pin",
        method="POST",
        headers={"X-Nephos-Identity-Service-Key": identity_admin_service_key},
    )["pin"]
    assert smoke.request(pin_base + "/pin-requests", headers=service_headers) == {"requests": []}
    smoke.request(
        token_url,
        data=urllib.parse.urlencode({**grant, "pin": replaced_pin}).encode(),
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        expected=400,
    )
    second_grant = {
        **grant,
        "pin": second_pin,
        "device_id": str(uuid.uuid4()),
        "device_name": "Identity smoke second device",
    }
    second_token_response = smoke.request(
        token_url,
        data=urllib.parse.urlencode(second_grant).encode(),
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )
    refreshed = smoke.request(
        token_url,
        data=urllib.parse.urlencode(
            {
                "grant_type": "refresh_token",
                "client_id": "nephos-ios",
                "refresh_token": second_token_response["refresh_token"],
            }
        ).encode(),
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )
    for token_type in ("access_token", "id_token"):
        encoded = refreshed[token_type].split(".")[1]
        claims = json.loads(base64.urlsafe_b64decode(encoded + "=" * (-len(encoded) % 4)))
        assert claims["sub"] == subject and claims.get("iss") == discovery["issuer"], (
            f"refreshed {token_type} must retain the canonical issuer and subject"
        )
    admin = admin_token()
    disabled_user = smoke.request(admin_base + "/users?exact=true&username=" + disabled_username, token=admin)[0]
    smoke.request(
        admin_base + "/users/" + disabled_user["id"],
        token=admin,
        method="PUT",
        data={"enabled": True},
        expected=204,
    )
    request_pin(disabled_username + "@example.test")
    disabled_pin = smoke.request(pin_base + "/pin-requests", headers=service_headers)["requests"][0]["pin"]
    smoke.request(
        admin_base + "/users/" + disabled_user["id"],
        token=admin,
        method="PUT",
        data={"enabled": False},
        expected=204,
    )
    assert request_pin(disabled_username + "@example.test", 404)["error"] == "account_unavailable"
    assert smoke.request(pin_base + "/pin-requests", headers=service_headers) == {"requests": []}
    smoke.request(
        token_url,
        data=urllib.parse.urlencode(
            {**grant, "username": disabled_username + "@example.test", "pin": disabled_pin}
        ).encode(),
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        expected=400,
    )
    introspection_client = {
        "clientId": "nephos-api-introspection",
        "enabled": True,
        "protocol": "openid-connect",
        "publicClient": False,
        "secret": introspection_secret,
        "standardFlowEnabled": False,
        "directAccessGrantsEnabled": False,
    }
    smoke.request(
        admin_base + "/clients",
        token=admin,
        method="POST",
        expected=201,
        data=introspection_client,
    )
    introspect_url = f"http://localhost:{port}/realms/nephos/protocol/openid-connect/token/introspect"
    introspection = smoke.request(
        introspect_url,
        basic="nephos-api-introspection:" + introspection_secret,
        data=urllib.parse.urlencode({"token": token_response["access_token"]}).encode(),
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )
    assert introspection["active"] is True
    devices = smoke.request(
        f"http://localhost:{port}/realms/nephos/nephos-admin/users/{subject}/devices",
        headers={"X-Nephos-Identity-Service-Key": identity_admin_service_key},
    )["devices"]
    assert len(devices) == 2, devices
    first_device = next(item for item in devices if item["name"] == "Identity smoke device")
    smoke.request(
        f"http://localhost:{port}/realms/nephos/nephos-admin/users/{subject}/devices/{first_device['id']}",
        method="DELETE",
        expected=204,
        headers={"X-Nephos-Identity-Service-Key": identity_admin_service_key},
    )
    revoked = smoke.request(
        introspect_url,
        basic="nephos-api-introspection:" + introspection_secret,
        data=urllib.parse.urlencode({"token": token_response["access_token"]}).encode(),
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )
    assert revoked["active"] is False
    remaining = smoke.request(
        introspect_url,
        basic="nephos-api-introspection:" + introspection_secret,
        data=urllib.parse.urlencode({"token": second_token_response["access_token"]}).encode(),
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )
    assert remaining["active"] is True
    smoke.request(
        token_url,
        data=urllib.parse.urlencode(
            {"grant_type": "refresh_token", "client_id": "nephos-ios", "refresh_token": token_response["refresh_token"]}
        ).encode(),
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        expected=400,
    )
    locked_email = "locked-" + username + "@example.test"
    smoke.request(
        admin_base + "/users",
        token=admin_token(),
        method="POST",
        expected=201,
        data={"username": "locked-" + username, "email": locked_email, "enabled": True},
    )
    request_pin(locked_email)
    locked_pending = smoke.request(pin_base + "/pin-requests", headers=service_headers)["requests"]
    locked_pin = next(item["pin"] for item in locked_pending if item["email"] == locked_email)
    wrong_pin = ("0" if locked_pin[0] != "0" else "1") + locked_pin[1:]
    for _ in range(10):
        smoke.request(
            token_url,
            data=urllib.parse.urlencode({**grant, "username": locked_email, "pin": wrong_pin}).encode(),
            headers={"Content-Type": "application/x-www-form-urlencoded"},
            expected=400,
        )
    request_pin(locked_email)
    assert smoke.request(pin_base + "/pin-requests", headers=service_headers)["requests"] == locked_pending
    smoke.request(
        token_url,
        data=urllib.parse.urlencode({**grant, "username": locked_email, "pin": locked_pin}).encode(),
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        expected=400,
    )
    print(
        "PASS: production startup, immediate PIN reuse without expiry extension, issuance/IP cooldowns, "
        "email validation/private-only PINs/consumption/replacement/disablement/attempt lockout, "
        "offline refresh and device revocation"
    )
except Exception:
    if identity in containers:
        print(docker("logs", "--tail", "30", identity))
    raise
finally:
    for container in reversed(containers):
        docker("rm", "-f", "-v", container)
    docker("network", "rm", network)
