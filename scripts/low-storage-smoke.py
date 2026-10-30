#!/usr/bin/env python3
"""Verify real upload rejection on a tiny temporary volume, without filling the host disk."""

import hashlib
import json
import os
import runpy
import socket
import subprocess
import uuid

import smoke

media = runpy.run_path(str(smoke.ROOT / "scripts/media-smoke.py"))
name = "nephos-low-storage-" + uuid.uuid4().hex


def docker(*args, environment=None):
    return subprocess.run(
        ["docker", *args], cwd=smoke.ROOT, check=True, capture_output=True, text=True, env=environment
    ).stdout.strip()


config = json.loads(docker("compose", "config", "--format", "json"))
environment = {**os.environ, **config["services"]["storage-api"]["environment"]}
container = docker("compose", "ps", "-q", "storage-api")
details = json.loads(docker("inspect", container))[0]
network = next(iter(details["NetworkSettings"]["Networks"]))
with socket.socket() as reservation:
    reservation.bind(("127.0.0.1", 0))
    port = reservation.getsockname()[1]
arguments = [
    "run",
    "-d",
    "--name",
    name,
    "--network",
    network,
    "--memory",
    "256m",
    "--read-only",
    "--cap-drop",
    "ALL",
    "--security-opt",
    "no-new-privileges:true",
    "--tmpfs",
    "/tmp:rw",
    "--tmpfs",
    "/data/media:rw,size=32m,uid=1654,gid=1654",
    "-p",
    f"127.0.0.1:{port}:8080",
]
for key in config["services"]["storage-api"]["environment"]:
    arguments.extend(["-e", key])
arguments.extend([details["Image"], "Nephos.Storage.Api.dll"])
started = False
try:
    docker(*arguments, environment=environment)
    started = True
    base = f"http://localhost:{port}"
    smoke.wait(
        "temporary low-capacity storage API is ready", lambda: smoke.request(base + "/health/ready") == "Healthy"
    )
    with media["account"]() as (token, _, library, uploads):
        identifier = str(uuid.uuid4())
        uploads.append(identifier)
        body = b"low-capacity-fixture"
        result = smoke.request(
            base + "/v1/uploads",
            token=token,
            expected=507,
            data={
                "id": identifier,
                "libraryId": library,
                "fileName": "fixture.bin",
                "mediaType": "application/octet-stream",
                "size": len(body),
                "sha256": hashlib.sha256(body).hexdigest(),
            },
        )
        assert "headroom" in result["title"]
        smoke.request(base + "/v1/uploads/" + identifier, token=token, expected=404)
        print(
            "PASS: real insufficient-volume headroom rejects admission without creating a resumable upload or touching originals"
        )
finally:
    if started:
        docker("rm", "-f", "-v", name)
