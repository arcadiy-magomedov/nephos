#!/usr/bin/env python3
"""Qualify real QR grants on an exclusively disposable production-mode identity stack."""

import argparse
import base64
import concurrent.futures
import hashlib
import json
import os
import secrets
import socket
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def b64(value):
    return base64.urlsafe_b64encode(value).rstrip(b"=").decode()


def request(url, data=None, method=None, headers=None, expected=200):
    headers = dict(headers or {})
    headers.setdefault("X-Forwarded-Proto", "https")
    headers.setdefault("X-Forwarded-Host", "photos.example.test")
    headers.setdefault("X-Forwarded-Port", "443")
    if isinstance(data, dict):
        data = json.dumps(data).encode()
        headers["Content-Type"] = "application/json"
    query = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        response = urllib.request.urlopen(query, timeout=20)
    except urllib.error.HTTPError as error:
        response = error
    with response:
        body = response.read()
        assert response.status == expected, f"{method or 'GET'} route failed: HTTP {response.status}, wanted {expected}"
        return json.loads(body) if body else None


def qualify(base, service_key, restart, sql, rotate):
    private = base + "/realms/nephos/nephos-admin"
    token_url = base + "/realms/nephos/protocol/openid-connect/token"
    headers = {"X-Nephos-Identity-Service-Key": service_key}
    subject, command = str(uuid.uuid4()), str(uuid.uuid4())
    provision = {
        "commandId": command,
        "requestHash": hashlib.sha256(command.encode()).hexdigest(),
        "login": "qr-" + uuid.uuid4().hex,
        "displayName": "QR qualification",
    }
    request(private + "/users/" + subject + "/provision", provision, "PUT", expected=401)
    identity = request(private + "/users/" + subject + "/provision", provision, "PUT", headers, 201)
    assert not identity["enabled"]
    assert request(private + "/users/" + subject + "/provision", provision, "PUT", headers)["subject"] == subject
    request(private + "/users/" + str(uuid.uuid4()) + "/provision", provision, "PUT", headers, 409)
    identity = request(
        private + "/users/" + subject + "/access",
        {"commandId": command, "expectedRevision": identity["revision"], "enabled": True},
        "PUT",
        headers,
    )
    config = request(private + "/enrollment/config")
    assert config["origin"] == "https://photos.example.test"

    def issue():
        command = str(uuid.uuid4())
        code = request(private + "/users/" + subject + "/invitations", {"commandId": command}, "POST", headers, 201)
        retry = request(private + "/users/" + subject + "/invitations", {"commandId": command}, "POST", headers)
        assert "qr" not in retry and retry["inviteId"] == code["inviteId"]
        return code

    def device(code):
        key = ec.generate_private_key(ec.SECP256R1())
        point = key.public_key().public_bytes(serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint)
        return {
            "key": key,
            "public": b64(point),
            "request": str(uuid.uuid4()),
            "nonce": str(uuid.uuid4()),
            "code": code,
        }

    def exchange(device, expected=200, mutate=None):
        challenge = request(
            private + "/enrollment/challenge",
            {
                "inviteId": device["code"]["inviteId"],
                "requestId": device["request"],
                "clientId": "nephos-ios",
                "publicKey": device["public"],
            },
            "POST",
        )
        text = base64.urlsafe_b64decode(challenge["challenge"] + "==")
        lines = text.decode().split("\n")
        assert lines[:5] == [
            "nephos-qr-v1",
            config["origin"],
            "nephos-ios",
            device["code"]["inviteId"],
            device["request"],
        ]
        assert lines[5] == b64(hashlib.sha256(base64.urlsafe_b64decode(device["public"] + "==")).digest())
        form = {
            "grant_type": config["grantType"],
            "client_id": "nephos-ios",
            "invite_id": device["code"]["inviteId"],
            "invite_secret": device["code"]["qr"]["secret"],
            "request_id": device["request"],
            "public_key": device["public"],
            "challenge_id": challenge["challengeId"],
            "signature": b64(device["key"].sign(text, ec.ECDSA(hashes.SHA256()))),
            "device_name": "QR qualification",
            "nonce": device["nonce"],
            "scope": "openid offline_access",
        }
        if mutate:
            form.update(mutate)
        return request(
            token_url,
            urllib.parse.urlencode(form).encode(),
            "POST",
            {"Content-Type": "application/x-www-form-urlencoded"},
            expected,
        )

    first_code = issue()
    first = device(first_code)
    tokens = exchange(first)
    assert {"access_token", "refresh_token", "id_token"} <= tokens.keys()
    assert exchange(first)["refresh_token"] == tokens["refresh_token"]
    assert exchange(device(first_code), 400)["error_description"] == "invite_used"
    assert exchange(first, 400, {"nonce": str(uuid.uuid4())})["error_description"] == "invite_used"
    # Verify persisted receipt and both representations, then cold restart.
    assert sql("SELECT count(*) FROM OFFLINE_USER_SESSION WHERE USER_ID = '" + subject + "'") == "2"
    restart()
    assert exchange(first)["refresh_token"] == tokens["refresh_token"]
    # Refresh progression always overrides receipt recovery, including rotation disabled.
    refreshed = request(
        token_url,
        urllib.parse.urlencode(
            {"grant_type": "refresh_token", "client_id": "nephos-ios", "refresh_token": tokens["refresh_token"]}
        ).encode(),
        "POST",
        {"Content-Type": "application/x-www-form-urlencoded"},
    )
    assert refreshed["refresh_token"]
    refreshed_id = json.loads(base64.urlsafe_b64decode(refreshed["id_token"].split(".")[1] + "=="))
    assert refreshed_id["iss"] == config["issuer"]
    assert refreshed_id.get("nonce", first["nonce"]) == first["nonce"]
    assert refreshed_id["sub"] == subject
    assert exchange(first, 400)["error_description"] in ("session_revoked", "recovery_expired")

    second = device(issue())
    second_tokens = exchange(second)
    devices = request(private + "/users/" + subject + "/devices", headers=headers)["devices"]
    assert len(devices) == 2
    id_payload = json.loads(base64.urlsafe_b64decode(second_tokens["access_token"].split(".")[1] + "=="))
    request(
        private + "/users/" + subject + "/devices/" + id_payload["sid"], method="DELETE", headers=headers, expected=204
    )
    assert exchange(second, 400)["error_description"] == "session_revoked"
    request(
        token_url,
        urllib.parse.urlencode(
            {"grant_type": "refresh_token", "client_id": "nephos-ios", "refresh_token": second_tokens["refresh_token"]}
        ).encode(),
        "POST",
        {"Content-Type": "application/x-www-form-urlencoded"},
        400,
    )
    # Cancel, expiry and durable concurrent claim.
    cancelled = device(issue())
    request(
        private + "/users/" + subject + "/invitations/" + cancelled["code"]["inviteId"],
        method="DELETE",
        headers=headers,
    )
    assert exchange(cancelled, 400)["error_description"] == "invite_cancelled"
    expired = device(issue())
    sql("UPDATE NEPHOS_ENROLLMENT SET EXPIRES_AT = 1 WHERE ID = 'invite:" + expired["code"]["inviteId"] + "'")
    assert exchange(expired, 400)["error_description"] == "invite_expired"
    raced = issue()
    contenders = [device(raced), device(raced)]

    def claim(item):
        try:
            return exchange(item)
        except AssertionError:
            return None

    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        winners = list(pool.map(claim, contenders))
    assert sum(value is not None for value in winners) == 1
    # Profile changes do not advance epoch or invalidate acquired sessions.
    identity = request(private + "/users/" + subject, headers=headers)
    epoch = identity["epoch"]
    identity = request(
        private + "/users/" + subject + "/profile",
        {"commandId": str(uuid.uuid4()), "expectedRevision": identity["revision"], "displayName": "Updated name"},
        "PUT",
        headers,
    )
    assert identity["epoch"] == epoch
    pending = device(issue())
    disable = {"commandId": str(uuid.uuid4()), "expectedRevision": identity["revision"], "enabled": False}
    identity = request(private + "/users/" + subject + "/access", disable, "PUT", headers)
    assert not identity["enabled"] and identity["epoch"] == epoch + 1
    request(private + "/users/" + subject + "/access", disable, "PUT", headers)
    assert exchange(pending, 400)["error_description"] == "user_disabled"
    assert request(private + "/users/" + subject + "/devices", headers=headers)["devices"] == []
    identity = request(
        private + "/users/" + subject + "/access",
        {"commandId": str(uuid.uuid4()), "expectedRevision": identity["revision"], "enabled": True},
        "PUT",
        headers,
    )
    assert exchange(pending, 400)["error_description"] == "session_revoked"
    request(private + "/users/" + subject + "/access", disable, "PUT", headers)
    assert request(private + "/users/" + subject, headers=headers)["enabled"]  # stale replay never disables anew
    listing = request(private + "/users?limit=1", headers=headers)
    assert listing["total"] >= 1 and listing["items"]
    fault = device(issue())
    before = sql("SELECT count(*) FROM OFFLINE_USER_SESSION WHERE USER_ID = '" + subject + "'")
    sql(
        "CREATE FUNCTION nephos_test_fail() RETURNS trigger LANGUAGE plpgsql AS $$ "
        "BEGIN IF NEW.KIND = 'request' THEN RAISE EXCEPTION 'qualification fault'; END IF; RETURN NEW; END $$; "
        "CREATE TRIGGER nephos_test_fail BEFORE INSERT ON NEPHOS_ENROLLMENT "
        "FOR EACH ROW EXECUTE FUNCTION nephos_test_fail()"
    )
    assert exchange(fault, 503)["error_description"] == "temporarily_unavailable"
    assert sql("SELECT count(*) FROM OFFLINE_USER_SESSION WHERE USER_ID = '" + subject + "'") == before
    sql("DROP TRIGGER nephos_test_fail ON NEPHOS_ENROLLMENT; DROP FUNCTION nephos_test_fail()")
    exchange(fault)
    assert int(sql("SELECT count(*) FROM OFFLINE_USER_SESSION WHERE USER_ID = '" + subject + "'")) == int(before) + 2
    unclaimed = device(issue())
    before = sql("SELECT count(*) FROM OFFLINE_USER_SESSION WHERE USER_ID = '" + subject + "'")
    rotate()
    assert exchange(fault, 400)["error_description"] == "session_revoked"
    assert exchange(unclaimed, 400)["error_description"] == "session_revoked"
    assert sql("SELECT count(*) FROM OFFLINE_USER_SESSION WHERE USER_ID = '" + subject + "'") == before
    exchange(device(issue()))
    print(
        "PASS: production QR claim/retry/restart/race/expiry/cancel/profile/refresh/revoke/disable/rollback/key rotation"
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--image", required=True, help="Locally built pinned production provider image")
    parser.add_argument("--postgres-image", default="postgres:18")
    args = parser.parse_args()
    prefix = "nephos-qr-qualification-" + uuid.uuid4().hex
    network, database, identity = prefix + "-net", prefix + "-db", prefix + "-id"
    key, password = secrets.token_hex(32), secrets.token_hex(32)
    env = {
        **os.environ,
        "POSTGRES_PASSWORD": password,
        "KC_DB_PASSWORD": password,
        "KC_BOOTSTRAP_ADMIN_PASSWORD": password,
        "IDENTITY_ADMIN_SERVICE_KEY": key,
        "NEPHOS_PIN_PEPPER": secrets.token_hex(32),
        "NEPHOS_PUBLIC_ORIGIN": "https://photos.example.test",
        "NEPHOS_QR_DELIVERY_KEY": base64.b64encode(secrets.token_bytes(32)).decode(),
    }

    def docker(*args):
        return subprocess.run(
            ["docker", *args], env=env, cwd=ROOT, check=True, capture_output=True, text=True
        ).stdout.strip()

    with socket.socket() as reservation:
        reservation.bind(("127.0.0.1", 0))
        port = reservation.getsockname()[1]
    base = f"http://localhost:{port}"

    def ready():
        for _ in range(150):
            try:
                request(base + "/realms/nephos/.well-known/openid-configuration")
                return
            except (OSError, AssertionError):
                time.sleep(1)
        raise RuntimeError("Disposable identity did not become ready")

    def restart():
        docker("restart", identity)
        ready()

    def rotate():
        env["NEPHOS_QR_DELIVERY_KEY"] = base64.b64encode(secrets.token_bytes(32)).decode()
        docker("rm", "-f", identity)
        start_identity()
        ready()

    def sql(statement):
        return docker("exec", database, "psql", "-U", "keycloak", "-d", "keycloak", "-tAc", statement)

    docker("network", "create", network)
    containers = []
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
            "-e",
            "POSTGRES_PASSWORD",
            "-e",
            "POSTGRES_USER=keycloak",
            "-e",
            "POSTGRES_DB=keycloak",
            args.postgres_image,
        )
        containers.append(database)
        for _ in range(60):
            try:
                sql("SELECT 1")
                break
            except subprocess.CalledProcessError:
                time.sleep(1)
        identity_args = (
            "run",
            "-d",
            "--name",
            identity,
            "--network",
            network,
            "--memory",
            "768m",
            "-e",
            "JAVA_OPTS_KC_HEAP=-Xms128m -Xmx384m",
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
            ROOT + "/deploy/keycloak/nephos-realm.json:/opt/keycloak/data/import/nephos-realm.json:ro",
            args.image,
            "start",
            "--optimized",
            "--import-realm",
        )

        def start_identity():
            docker(*identity_args)

        start_identity()
        containers.append(identity)
        ready()
        qualify(base, key, restart, sql, rotate)
    except Exception:
        if identity in containers:
            print(docker("logs", "--tail", "40", identity))
        raise
    finally:
        for container in reversed(containers):
            docker("rm", "-f", "-v", container)
        docker("network", "rm", network)


if __name__ == "__main__":
    main()
