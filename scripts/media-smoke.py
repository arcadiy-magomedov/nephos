#!/usr/bin/env python3
"""Real media-path acceptance checks against the disposable local Compose stack."""

from contextlib import contextmanager
import hashlib
import json
import secrets
import struct
import subprocess
import urllib.error
import urllib.parse
import urllib.request
import uuid
import zlib

import smoke

request = smoke.request
API = smoke.API


def compose(*args):
    subprocess.run(["docker", "compose", *args], cwd=smoke.ROOT, check=True, capture_output=True)


def raw(path, token, data=None, method="GET", expected=200, headers=None):
    supplied = {"Authorization": "Bearer " + token, **(headers or {})}
    req = urllib.request.Request(API + path, data=data, method=method, headers=supplied)
    try:
        with urllib.request.urlopen(req, timeout=60) as response:
            status, body, response_headers = response.status, response.read(), response.headers
    except urllib.error.HTTPError as error:
        status, body, response_headers = error.code, error.read(), error.headers
    assert status == expected, f"{method} {path}: expected {expected}, received {status}"
    return body, response_headers


@contextmanager
def account():
    client = "media-smoke-" + uuid.uuid4().hex
    secret = secrets.token_hex(24)
    admin_url = smoke.IDENTITY + "/admin/realms/nephos"
    admin = smoke.admin_token()
    request(
        admin_url + "/clients",
        method="POST",
        token=admin,
        expected=201,
        data={
            "clientId": client,
            "secret": secret,
            "enabled": True,
            "publicClient": False,
            "serviceAccountsEnabled": True,
            "standardFlowEnabled": False,
            "protocolMappers": [
                {
                    "name": "api",
                    "protocol": "openid-connect",
                    "protocolMapper": "oidc-audience-mapper",
                    "config": {"included.custom.audience": "nephos-api", "access.token.claim": "true"},
                }
            ],
        },
    )
    internal = request(admin_url + "/clients?clientId=" + client, token=admin)[0]["id"]
    subject = request(admin_url + f"/clients/{internal}/service-account-user", token=admin)["id"]
    library = str(uuid.uuid4())
    uploads = []
    try:
        smoke.sql(
            """
            INSERT INTO principals(subject,enabled) VALUES(:'subject',true);
            INSERT INTO libraries(id,name) VALUES(:'library'::uuid,'Media smoke');
            INSERT INTO library_members(subject,library_id) VALUES(:'subject',:'library'::uuid);
            """,
            subject=subject,
            library=library,
        )
        token = smoke.token_for(
            "nephos", {"grant_type": "client_credentials", "client_id": client, "client_secret": secret}
        )
        yield token, subject, library, uploads
    finally:
        for upload in uploads:
            smoke.sql("DELETE FROM assets WHERE id=:'id'::uuid;", id=upload)
        smoke.sql(
            """
            DELETE FROM library_members WHERE subject=:'subject';
            DELETE FROM principals WHERE subject=:'subject';
            DELETE FROM libraries WHERE id=:'library'::uuid;
            """,
            subject=subject,
            library=library,
        )
        statement = """
            BEGIN;
            CREATE TEMP TABLE cleanup_hashes AS SELECT sha256 FROM uploads WHERE subject=:'subject' AND sha256 IS NOT NULL;
            DELETE FROM retention_holds WHERE asset_id IN (SELECT id FROM uploads WHERE subject=:'subject');
            DELETE FROM outbox WHERE id IN (SELECT id FROM uploads WHERE subject=:'subject');
            DELETE FROM upload_parts WHERE upload_id IN (SELECT id FROM uploads WHERE subject=:'subject');
            DELETE FROM blob_references WHERE asset_id IN (SELECT id FROM uploads WHERE subject=:'subject');
            DELETE FROM uploads WHERE subject=:'subject';
            DELETE FROM blobs WHERE sha256 IN (SELECT sha256 FROM cleanup_hashes)
              AND NOT EXISTS(SELECT 1 FROM blob_references r WHERE r.sha256=blobs.sha256) RETURNING sha256;
            COMMIT;
        """
        result = subprocess.run(
            [
                "docker",
                "compose",
                "exec",
                "-T",
                "postgres",
                "psql",
                "-U",
                "postgres",
                "-d",
                "storage",
                "-v",
                "ON_ERROR_STOP=1",
                "-v",
                f"subject={subject}",
                "-Atq",
            ],
            input=statement,
            text=True,
            capture_output=True,
            check=True,
            cwd=smoke.ROOT,
        )
        for digest in result.stdout.splitlines():
            assert len(digest) == 64 and all(c in "0123456789abcdef" for c in digest)
            compose(
                "exec",
                "-T",
                "storage-api",
                "rm",
                "-f",
                "--",
                "/data/media/blobs/" + digest[:2] + "/" + digest,
                "/data/media/previews/" + digest + ".jpg",
            )
        smoke.wait(
            "identity available for fixture cleanup",
            lambda: request(smoke.IDENTITY + "/realms/nephos/.well-known/openid-configuration"),
        )
        request(admin_url + "/clients/" + internal, method="DELETE", token=smoke.admin_token(), expected=204)


def intent(token, library, uploads, body, media_type="application/octet-stream", captured_at=None):
    identifier = str(uuid.uuid4())
    uploads.append(identifier)
    value = {
        "id": identifier,
        "libraryId": library,
        "fileName": "fixture.png" if media_type == "image/png" else "fixture.bin",
        "mediaType": media_type,
        "size": len(body),
        "sha256": hashlib.sha256(body).hexdigest(),
    }
    if captured_at:
        value["capturedAt"] = captured_at
    status = request(API + "/v1/uploads", token=token, data=value)
    return value, status


def ready(token, identifier):
    def check():
        state = request(API + "/v1/uploads/" + identifier, token=token)
        if state["state"] == "failed":
            raise RuntimeError("Verification failed: " + str(state["error"]))
        return state if state["state"] == "ready" else None

    return smoke.wait("asset committed through verification/outbox/RabbitMQ/projection", check, timeout=120)


def png():
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", 2, 2, 8, 2, 0, 0, 0))
        + chunk(b"tEXt", b"Fixture\x00" + uuid.uuid4().hex.encode())
        + chunk(b"IDAT", zlib.compress(b"\x00\xff\x00\x00\x00\xff\x00" * 2))
        + chunk(b"IEND", b"")
    )


def main():
    smoke.wait("library ready", lambda: request(API + "/health/library") == "Healthy")
    smoke.wait("storage ready", lambda: request(API + "/health/storage") == "Healthy")
    smoke.wait("identity ready", lambda: request(smoke.IDENTITY + "/realms/nephos/.well-known/openid-configuration"))
    config = request(API + "/v1/config")
    assert config["chunkSize"] == 4194304 and config["serverId"]
    with account() as (token, subject, library, uploads), account() as (other, _, other_library, other_uploads):
        data = secrets.token_bytes(2 * config["chunkSize"] + 17)
        value, status = intent(token, library, uploads, data, captured_at="2018-02-03T12:00:00Z")
        identifier = status["id"]
        assert request(API + "/v1/uploads", token=token, data=value)["id"] == identifier
        path = "/v1/uploads/" + identifier
        request(API + path, token=other, expected=404)
        request(API + "/v1/uploads", token=other, data={**value, "id": str(uuid.uuid4())}, expected=403)
        request(API + path + "/complete", token=token, method="POST", expected=409)
        chunks = [data[i : i + config["chunkSize"]] for i in range(0, len(data), config["chunkSize"])]
        raw(path + "/parts/1", token, chunks[1], "PUT", 204)
        raw(path + "/parts/1", token, chunks[1], "PUT", 204)
        raw(path + "/parts/1", token, bytes([chunks[1][0] ^ 1]) + chunks[1][1:], "PUT", 409)
        compose("restart", "storage-api")
        smoke.wait("upload API recovers after restart", lambda: request(API + "/health/storage") == "Healthy")
        resumed = request(API + path, token=token)
        assert resumed["receivedParts"] == [1]
        for part in (2, 0):
            raw(path + "/parts/" + str(part), token, chunks[part], "PUT", 204)
        compose("stop", "rabbitmq")
        trace_id = uuid.uuid4().hex
        try:
            request(
                API + path + "/complete",
                token=token,
                method="POST",
                expected=202,
                headers={"traceparent": f"00-{trace_id}-{secrets.token_hex(8)}-01"},
            )
            assert request(API + path, token=token)["state"] == "verifying"
            request(API + "/v1/assets/" + identifier + "/original", token=token, expected=404)
        finally:
            compose("start", "rabbitmq")
        ready(token, identifier)

        def trace_complete():
            trace = request(
                smoke.GRAFANA + "/api/datasources/proxy/uid/tempo/api/traces/" + trace_id,
                basic="admin:" + smoke.ENV["GRAFANA_PASSWORD"],
            )
            text = json.dumps(trace)
            return "verify original" in text and "project verified asset" in text and "publish verified asset" in text

        smoke.wait("trace follows HTTP, durable verification, RabbitMQ and projection", trace_complete)
        original, _ = raw("/v1/assets/" + identifier + "/original", token)
        assert original == data
        partial, headers = raw(
            "/v1/assets/" + identifier + "/original", token, expected=206, headers={"Range": "bytes=4-31"}
        )
        assert partial == data[4:32] and headers["Content-Range"] == f"bytes 4-31/{len(data)}"
        request(API + "/v1/assets/" + identifier + "/original", token=other, expected=404)
        request(API + "/v1/assets/" + identifier + "/retention", token=other, method="POST", expected=404)
        hold = request(API + "/v1/assets/" + identifier + "/retention", token=token, method="POST")
        assert (
            hold["sha256"] == value["sha256"]
            and hold["holdId"]
            and hold["assurance"] == "single-volume-no-independent-backup"
        )
        assert request(API + "/v1/uploads", token=token, data={**value, "id": str(uuid.uuid4())})["id"] == identifier
        print(
            "PASS: out-of-order immutable chunks, restart/resume, broker recovery, exact original/range, isolation and retention"
        )

        duplicate, second = intent(other, other_library, other_uploads, data)
        assert second["state"] == "uploading", "Cross-user hash knowledge must not skip proof of bytes"
        for part, body in enumerate(chunks):
            raw("/v1/uploads/" + second["id"] + "/parts/" + str(part), other, body, "PUT", 204)
        request(API + "/v1/uploads/" + second["id"] + "/complete", token=other, method="POST", expected=202)
        ready(other, second["id"])
        result = subprocess.check_output(
            [
                "docker",
                "compose",
                "exec",
                "-T",
                "postgres",
                "psql",
                "-U",
                "postgres",
                "-d",
                "storage",
                "-Atc",
                "SELECT count(*) FROM blobs WHERE sha256='" + value["sha256"] + "'",
            ],
            cwd=smoke.ROOT,
            text=True,
        )
        assert result.strip() == "1"
        print("PASS: cross-user upload proves bytes and shares one physical blob with separate references")

        image = png()
        _, image_status = intent(token, library, uploads, image, "image/png", "2020-05-06T12:00:00Z")
        raw("/v1/uploads/" + image_status["id"] + "/parts/0", token, image, "PUT", 204)
        request(API + "/v1/uploads/" + image_status["id"] + "/complete", token=token, method="POST", expected=202)
        ready(token, image_status["id"])
        thumbnail, _ = raw("/v1/assets/" + image_status["id"] + "/preview", token)
        assert thumbnail.startswith(b"\xff\xd8")
        first = request(API + "/v1/libraries/" + library + "/assets?limit=1", token=token)
        cursor = first["nextCursor"]
        assert cursor and len(first["items"]) == 1
        second_page = request(
            API
            + "/v1/libraries/"
            + library
            + "/assets?"
            + urllib.parse.urlencode({"limit": 1, "before": cursor["createdAt"], "beforeId": cursor["id"]}),
            token=token,
        )
        assert {first["items"][0]["id"], second_page["items"][0]["id"]} == {identifier, image_status["id"]}
        assert second_page["nextCursor"] is None
        timeline = request(API + "/v1/libraries/" + library + "/timeline", token=token)
        assert timeline["items"] == [{"date": "2020-01-01", "count": 1}, {"date": "2018-01-01", "count": 1}]
        days = request(API + "/v1/libraries/" + library + "/timeline?year=2020&month=5", token=token)
        assert days["items"] == [{"date": "2020-05-06", "count": 1}]
        request(API + "/v1/libraries/" + library + "/assets", token=other, expected=404)
        print("PASS: real PNG preview, capture-date chronology, layered counts, pages and cross-library authorization")

        bad, bad_status = intent(token, library, uploads, b"expected")
        raw("/v1/uploads/" + bad_status["id"] + "/parts/0", token, b"tampered", "PUT", 204)
        request(API + "/v1/uploads/" + bad_status["id"] + "/complete", token=token, method="POST", expected=202)
        smoke.wait(
            "hash mismatch rejected",
            lambda: request(API + "/v1/uploads/" + bad_status["id"], token=token)["state"] == "failed",
        )
        request(API + "/v1/assets/" + bad_status["id"] + "/original", token=token, expected=404)
        smoke.sql("UPDATE principals SET enabled=false WHERE subject=:'subject';", subject=subject)
        request(API + "/v1/assets/" + identifier + "/original", token=token, expected=404)
        request(API + path, token=token, expected=404)
        print("PASS: corrupt originals never publish; disablement stops upload and original access")
    print("Media MVP acceptance checks passed; test accounts and originals removed.")


if __name__ == "__main__":
    main()
