#!/usr/bin/env python3
"""Exercise the actual Caddy route allowlist without public DNS or certificate issuance."""

import json
import socket
import subprocess
import uuid

import smoke

name = "nephos-edge-smoke-" + uuid.uuid4().hex


def docker(*args):
    return subprocess.run(["docker", *args], cwd=smoke.ROOT, check=True, capture_output=True, text=True).stdout.strip()


with socket.socket() as reservation:
    reservation.bind(("127.0.0.1", 0))
    port = reservation.getsockname()[1]
gateway = docker("compose", "ps", "-q", "gateway")
network = next(iter(json.loads(docker("inspect", gateway))[0]["NetworkSettings"]["Networks"]))
image = "caddy:2.10-alpine@sha256:4c6e91c6ed0e2fa03efd5b44747b625fec79bc9cd06ac5235a779726618e530d"
try:
    docker(
        "run",
        "-d",
        "--name",
        name,
        "--network",
        network,
        "-p",
        f"127.0.0.1:{port}:{port}",
        "-e",
        f"PUBLIC_HOST=http://localhost:{port}",
        "-v",
        str(smoke.ROOT / "deploy/Caddyfile") + ":/etc/caddy/Caddyfile:ro",
        image,
    )
    base = f"http://localhost:{port}"
    smoke.wait("temporary edge responds with public setup", lambda: smoke.request(base + "/v1/config")["serverId"])
    discovery = smoke.request(base + "/realms/nephos/.well-known/openid-configuration")
    assert discovery["issuer"].endswith("/realms/nephos")
    smoke.request(base + "/v1/libraries", expected=401)
    for path in (
        "/admin/",
        "/realms/master/.well-known/openid-configuration",
        "/internal/admin/state",
        "/metrics",
        "/health/ready",
        "/api/datasources",
        "/",
    ):
        smoke.request(base + path, expected=404)
    print(
        "PASS: actual edge exposes application/login routes and rejects administration, master realm and observability"
    )
finally:
    docker("rm", "-f", "-v", name)
