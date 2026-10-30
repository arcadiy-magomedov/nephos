#!/usr/bin/env python3
"""Boot production-mode Keycloak against a disposable isolated PostgreSQL instance."""

import json
import os
import secrets
import socket
import subprocess
import uuid

import smoke

prefix = "nephos-identity-smoke-" + uuid.uuid4().hex
database, identity, network = prefix + "-db", prefix + "-identity", prefix + "-network"
password = secrets.token_hex(24)
environment = {
    **os.environ,
    "POSTGRES_PASSWORD": password,
    "KC_DB_PASSWORD": password,
    "KC_BOOTSTRAP_ADMIN_PASSWORD": password,
}
containers = []


def docker(*args):
    return subprocess.run(
        ["docker", *args], env=environment, cwd=smoke.ROOT, check=True, capture_output=True, text=True
    ).stdout.strip()


configuration = json.loads(docker("compose", "config", "--format", "json"))
postgres_image = configuration["services"]["postgres"]["image"]
identity_image = configuration["services"]["keycloak"]["image"]
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
    print("PASS: actual production startup, PostgreSQL realm import, canonical HTTPS issuer and proxy-aware discovery")
except Exception:
    if identity in containers:
        print(docker("logs", "--tail", "30", identity))
    raise
finally:
    for container in reversed(containers):
        docker("rm", "-f", "-v", container)
    docker("network", "rm", network)
