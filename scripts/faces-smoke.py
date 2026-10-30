#!/usr/bin/env python3
"""Real development-stack face acceptance; never run against a production realm.

Uses existing disposable Keycloak/admin fixture helpers. All media and face API
operations use real signed JWTs and live Library authorization. No fake inference
or authentication override is installed. Only the optional face API/worker restart.
"""

import hashlib
import json
import math
import re
import runpy
import struct
import subprocess
import time
import urllib.parse
import uuid
import zlib

import smoke

ROOT, API, request = smoke.ROOT, smoke.API, smoke.request
media = runpy.run_path(str(ROOT / "scripts/media-smoke.py"))
COMPOSE = [
    "docker",
    "compose",
    "--env-file",
    ".env",
    "--env-file",
    ".env.faces",
    "-f",
    "compose.yaml",
    "-f",
    "compose.faces.yaml",
]
REPORT = ROOT / "artifacts/faces-live-smoke.json"
EXPECTED_FIXTURES = ["obama-2009", "obama-2012", "biden-2013", "biden-2021", "trump-2017", "trump-2025"]


def face_sql(statement, subject):
    uuid.UUID(subject)
    result = subprocess.run(
        COMPOSE
        + [
            "exec",
            "-T",
            "faces-postgres",
            "psql",
            "-U",
            "postgres",
            "-d",
            "faces",
            "-v",
            "ON_ERROR_STOP=1",
            "-v",
            "subject=" + subject,
            "-Atq",
        ],
        input=statement,
        text=True,
        capture_output=True,
        check=True,
        cwd=ROOT,
        timeout=30,
    )
    return result.stdout.strip()


def cleanup_faces(subject):
    face_sql(
        """
        BEGIN;
        DELETE FROM observations WHERE owner=:'subject';
        DELETE FROM generated_clusters WHERE owner=:'subject';
        DELETE FROM track_exclusions WHERE owner=:'subject';
        DELETE FROM negative_matches WHERE owner=:'subject';
        DELETE FROM face_tracks WHERE owner=:'subject';
        DELETE FROM corrections WHERE owner=:'subject';
        UPDATE people SET redirect_id=NULL WHERE owner=:'subject';
        DELETE FROM people WHERE owner=:'subject';
        DELETE FROM jobs WHERE owner=:'subject';
        COMMIT;
        """,
        subject,
    )


def page_all(path, token, limit=2):
    rows, seen = [], set()
    after = None
    for _ in range(50):
        query = {"limit": limit}
        if after:
            query["after"] = after
        page = request(API + path + ("&" if "?" in path else "?") + urllib.parse.urlencode(query), token=token)
        assert len(page["items"]) <= limit, "Unbounded face result page"
        rows.extend(page["items"])
        after = page["next"]
        if after is None:
            return rows
        assert after not in seen, "Face pagination cursor did not advance"
        seen.add(after)
    raise AssertionError("Face pagination exceeded the fixture's bounded 50-page budget")


def upload(token, library, uploads, data, filename, media_type="image/jpeg", resource_set=None):
    identifier = str(uuid.uuid4())
    uploads.append(identifier)
    intent = {
        "id": identifier,
        "libraryId": library,
        "fileName": filename,
        "mediaType": media_type,
        "size": len(data),
        "sha256": hashlib.sha256(data).hexdigest(),
        "capturedAt": "2020-05-06T12:00:00Z",
    }
    if resource_set:
        intent["resourceSetId"] = resource_set
    status = request(API + "/v1/uploads", token=token, data=intent)
    assert status["id"] == identifier, "Unexpected fixture asset reuse"
    chunk_size = request(API + "/v1/config")["chunkSize"]
    assert 0 < chunk_size <= 8 * 1024 * 1024
    if status["state"] == "uploading":
        for offset in range(0, len(data), chunk_size):
            media["raw"](
                f"/v1/uploads/{identifier}/parts/{offset // chunk_size}",
                token,
                data[offset : offset + chunk_size],
                "PUT",
                204,
            )
        request(API + f"/v1/uploads/{identifier}/complete", token=token, method="POST", expected=202)
    media["ready"](token, identifier)
    if not resource_set:

        def exact_original():
            original, _ = media["raw"](f"/v1/assets/{identifier}/original", token)
            assert original == data and hashlib.sha256(original).hexdigest() == intent["sha256"]
            return True

        smoke.wait("immutable original retrievable after actual Library projection", exact_original)
    return intent


def automatic_jobs(token, assets, timeout=180, expected_status="complete"):
    ids = {asset["id"] for asset in assets}

    def completed():
        rows = [job for job in page_all("/v1/faces/jobs", token) if job["assetId"] in ids]
        assert len({job["assetId"] for job in rows}) == len(rows), "Automatic publication duplicated current-model jobs"
        for job in rows:
            if job["status"] in ("error", "denied"):
                raise RuntimeError(f"Real face job ended {job['status']}: {job['error']}")
            if job["status"] == "no_faces" and expected_status != "no_faces":
                raise RuntimeError("The real detector found no face in a labelled portrait")
        if len(rows) == len(ids) and all(job["status"] == expected_status for job in rows):
            return rows
        return None

    return smoke.wait(
        "automatic committed-publication face jobs finish without manual enqueue", completed, timeout=timeout
    )


def publication_retry_recorded(asset_id):
    uuid.UUID(asset_id)
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
            "library",
            "-v",
            "ON_ERROR_STOP=1",
            "-v",
            "asset=" + asset_id,
            "-Atq",
        ],
        input="SELECT attempts>=1 AND delivered_at IS NULL FROM face_publications WHERE asset_id=:'asset'::uuid;",
        text=True,
        capture_output=True,
        check=True,
        cwd=ROOT,
        timeout=15,
    )
    return result.stdout.strip() == "t"


def face_for(token, asset_id):
    rows = page_all("/v1/faces/observations?assetId=" + asset_id, token)
    assert len(rows) == 1, f"Expected one actual portrait observation, observed {len(rows)}"
    face = rows[0]
    assert face["quality"] == "usable" and face["personId"]
    assert 0 <= face["x"] < 1 and 0 <= face["y"] < 1
    assert 0 < face["width"] <= 1 and 0 < face["height"] <= 1
    assert face["x"] + face["width"] <= 1.00001 and face["y"] + face["height"] <= 1.00001
    assert "embedding" not in face, "Biometric vectors must not be exposed by public face APIs"
    return face


def restart_faces(token):
    subprocess.run(
        COMPOSE + ["restart", "faces-api", "faces-worker"], cwd=ROOT, check=True, capture_output=True, timeout=60
    )
    smoke.wait(
        "face API/worker restart preserves real JWT-authorized availability",
        lambda: request(API + "/v1/faces/people?limit=1", token=token),
    )


def admin_access(subject, enabled):
    basic = "admin:" + smoke.ENV["KEYCLOAK_ADMIN_PASSWORD"]
    page = request("http://localhost:18082/", basic=basic)
    csrf = re.search(r'name="csrf" value="([^"]+)"', page)[1]
    values = {"csrf": csrf, "action": "access", "subject": subject}
    if enabled:
        values["enabled"] = "yes"
    result = request(
        "http://localhost:18082/",
        basic=basic,
        data=urllib.parse.urlencode(values).encode(),
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )
    assert "Platform membership updated" in result


def blank_png():
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    width, height = 320, 240
    pixels = (b"\x00" + b"\xff\xff\xff" * width) * height
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
        + chunk(b"tEXt", b"Fixture\x00" + uuid.uuid4().hex.encode())
        + chunk(b"IDAT", zlib.compress(pixels))
        + chunk(b"IEND", b"")
    )


def live_similarities(subject, fixtures, assets):
    # Read only this newly-created fixture owner's six public-portrait vectors for
    # empirical measurement. These are deliberately absent from the public API.
    rows = json.loads(
        face_sql(
            """
        SELECT coalesce(json_agg(row_to_json(result)),'[]') FROM (
          SELECT j.asset_id AS "assetId",o.embedding,o.model_version AS "modelVersion"
          FROM observations o JOIN jobs j ON j.id=o.job_id
          WHERE o.owner=:'subject' AND j.status='complete'
          ORDER BY j.asset_id LIMIT 64
        ) result;
        """,
            subject,
        )
    )
    vectors = {row["assetId"]: row["embedding"] for row in rows}

    def cosine(left, right):
        assert len(left) == len(right) == 128
        return sum(a * b for a, b in zip(left, right)) / math.sqrt(sum(v * v for v in left) * sum(v * v for v in right))

    matrix = [[round(cosine(vectors[a["id"]], vectors[b["id"]]), 6) for b in assets] for a in assets]
    same, different = [], []
    for i, left in enumerate(fixtures):
        for j in range(i + 1, len(fixtures)):
            value = {"left": left["id"], "right": fixtures[j]["id"], "similarity": matrix[i][j]}
            (same if left["label"] == fixtures[j]["label"] else different).append(value)
    return {
        "thresholdFixedBeforeTesting": 0.45,
        "order": EXPECTED_FIXTURES,
        "matrix": matrix,
        "samePersonPairs": same,
        "differentPersonPairs": different,
        "falsePairSplits": [pair for pair in same if pair["similarity"] < 0.45],
        "falsePairMerges": [pair for pair in different if pair["similarity"] >= 0.45],
    }


def main():
    started = time.monotonic()
    report = {
        "status": "running",
        "boundary": "Real Keycloak JWT -> upload/hash/storage/RabbitMQ/Library projection -> automatic jobs -> private CPU inference",
        "sourceLabels": "Publisher metadata only; no visual identity inference.",
        "inference": "Actual pinned YuNet/SFace container; no fake detector or fixture authorization adapter.",
    }
    REPORT.parent.mkdir(exist_ok=True)
    fixtures = json.loads((ROOT / "face-inference/fixtures/provenance.json").read_text())
    assert [row["id"] for row in fixtures] == EXPECTED_FIXTURES
    originals = [(ROOT / "face-inference/fixtures/photos" / (row["id"] + ".jpg")).read_bytes() for row in fixtures]
    for fixture, data in zip(fixtures, originals):
        assert hashlib.sha256(data).hexdigest() == fixture["sha256"]
        assert len(data) == fixture["bytes"] and len(data) <= 20 * 1024 * 1024
    report["fixtures"] = [{key: value for key, value in row.items()} for row in fixtures]
    try:
        smoke.wait("Library ready", lambda: request(API + "/health/library") == "Healthy")
        smoke.wait("Storage ready", lambda: request(API + "/health/storage") == "Healthy")
        smoke.wait(
            "Keycloak ready", lambda: request(smoke.IDENTITY + "/realms/nephos/.well-known/openid-configuration")
        )
        request(API + "/v1/faces/people", expected=401)
        request(API + "/internal/faces/jobs", method="POST", data={}, expected=404)
        with (
            media["account"]() as (owner, owner_id, library, uploads),
            media["account"]() as (reader, reader_id, reader_library, reader_uploads),
            media["account"]() as (outsider, outsider_id, _, _),
        ):
            subjects = [owner_id, reader_id, outsider_id]
            report["fixtureSubjects"] = subjects
            share_id = None
            disabled = False
            try:
                request(API + "/v1/analysis/access", token=owner, expected=204)
                request(API + "/v1/faces/people?limit=101", token=owner, expected=400)
                assets = [
                    upload(owner, library, uploads, data, fixture["id"] + ".jpg")
                    for fixture, data in zip(fixtures, originals)
                ]
                # Automatic delivery is established before exercising any manual enqueue route.
                jobs = automatic_jobs(owner, assets)
                report["automaticJobs"] = jobs
                report["similarities"] = live_similarities(owner_id, fixtures, assets)
                REPORT.write_text(json.dumps(report, indent=2) + "\n")
                faces = [face_for(owner, asset["id"]) for asset in assets]
                identities = {}
                for fixture, asset, face in zip(fixtures, assets, faces):
                    assert face["sourceSha256"] == asset["sha256"]
                    label = fixture["label"]
                    if label in identities:
                        assert face["personId"] == identities[label], "Observed a genuine same-person false split"
                    else:
                        identities[label] = face["personId"]
                assert len(set(identities.values())) == 3, "Observed a genuine cross-person false merge"
                assert len(page_all("/v1/faces/people", owner)) == 3
                assert not report["similarities"]["falsePairSplits"] and not report["similarities"]["falsePairMerges"]
                for label, person in identities.items():
                    request(
                        API + f"/v1/faces/people/{person}/name",
                        token=owner,
                        method="PUT",
                        data={"name": label, "aliases": ["Publisher: " + label]},
                        expected=204,
                    )
                    assert len(page_all(f"/v1/faces/people/{person}/assets", owner)) == 2
                report["initialClusters"] = [
                    {"name": label, "personId": person, "members": 2} for label, person in identities.items()
                ]
                for asset in assets:
                    manual = request(API + "/v1/faces/jobs/" + asset["id"], token=owner, method="POST", expected=202)
                    assert manual["id"] == next(job["id"] for job in jobs if job["assetId"] == asset["id"])
                assert len(page_all("/v1/faces/jobs", owner)) == 6
                print(
                    "PASS: six exact originals, automatic real inference, three publisher-labelled clusters and idempotent enqueue"
                )

                smoke.sql(
                    "UPDATE principals SET display_name='Face reader',discoverable=true WHERE subject=:'subject';",
                    subject=reader_id,
                )
                share_id = str(uuid.uuid4())
                request(
                    API + "/v1/shares/" + share_id,
                    token=owner,
                    method="PUT",
                    data={
                        "libraryId": library,
                        "recipientId": reader_id,
                        "allAssets": False,
                        "assetIds": [assets[0]["id"]],
                    },
                )
                assert media["raw"]("/v1/assets/" + assets[0]["id"] + "/original", reader)[0] == originals[0]
                person = faces[0]["personId"]
                for token in (reader, outsider):
                    request(API + f"/v1/faces/people/{person}", token=token, expected=404)
                    request(
                        API + f"/v1/faces/people/{person}/name",
                        token=token,
                        method="PUT",
                        data={"name": "Forbidden", "aliases": []},
                        expected=404,
                    )
                    request(API + "/v1/faces/jobs/" + assets[0]["id"], token=token, method="POST", expected=404)
                    request(API + "/v1/faces/jobs/" + jobs[0]["id"], token=token, expected=404)
                    assert page_all("/v1/faces/observations?assetId=" + assets[0]["id"], token) == []
                    assert page_all(f"/v1/faces/people/{person}/assets", token) == []
                    assert page_all("/v1/faces/corrections", token) == []
                independent = upload(reader, reader_library, reader_uploads, originals[0], "independent-owner-copy.jpg")
                automatic_jobs(reader, [independent])
                private_person = face_for(reader, independent["id"])["personId"]
                assert private_person != person
                request(
                    API + f"/v1/faces/people/{private_person}/name",
                    token=reader,
                    method="PUT",
                    data={"name": "Independent private annotation", "aliases": []},
                    expected=204,
                )
                request(API + f"/v1/faces/people/{private_person}", token=owner, expected=404)
                assert request(API + f"/v1/faces/people/{person}", token=owner)["name"] == fixtures[0]["label"]
                report["privacy"] = {
                    "outsiderDenied": True,
                    "sharedReaderGetsMediaNotAnnotations": True,
                    "identicalOriginalIndependentPrivateIdentity": True,
                }
                print("PASS: cross-owner/shared-reader privacy and independent labels for identical original bytes")

                primary, merged = list(identities.values())[:2]
                request(
                    API + f"/v1/faces/people/{merged}/merge",
                    token=owner,
                    method="POST",
                    data={"targetId": primary},
                    expected=204,
                )
                restart_faces(owner)
                assert request(API + f"/v1/faces/people/{merged}", token=owner)["redirectId"] == primary
                assert len(page_all(f"/v1/faces/people/{primary}/assets", owner)) == 4
                for label, person in identities.items():
                    value = request(API + f"/v1/faces/people/{person}", token=owner)
                    assert value["name"] == label and value["aliases"] == ["Publisher: " + label]
                request(API + f"/v1/faces/people/{merged}/merge", token=owner, method="DELETE", expected=204)
                assert len(page_all(f"/v1/faces/people/{primary}/assets", owner)) == 2
                assert len(page_all(f"/v1/faces/people/{merged}/assets", owner)) == 2
                split_face = faces[1]
                request(
                    API + f"/v1/faces/observations/{split_face['id']}/person",
                    token=owner,
                    method="PUT",
                    data={"newPerson": True},
                    expected=204,
                )
                split_person = face_for(owner, assets[1]["id"])["personId"]
                assert split_person != primary
                request(
                    API + f"/v1/faces/people/{split_person}/name",
                    token=owner,
                    method="PUT",
                    data={"name": "Temporary corrected group", "aliases": []},
                    expected=204,
                )
                restart_faces(owner)
                persisted = face_for(owner, assets[1]["id"])
                assert persisted["id"] == split_face["id"] and persisted["personId"] == split_person
                assert request(API + f"/v1/faces/people/{merged}", token=owner)["redirectId"] is None
                assert (
                    request(API + f"/v1/faces/people/{split_person}", token=owner)["name"]
                    == "Temporary corrected group"
                )
                request(
                    API + f"/v1/faces/people/{split_person}/merge",
                    token=owner,
                    method="POST",
                    data={"targetId": primary},
                    expected=204,
                )
                assert len(page_all(f"/v1/faces/people/{primary}/assets", owner)) == 2
                corrections = page_all("/v1/faces/corrections", owner)
                assert {"name", "merge", "unmerge", "split"} <= {row["kind"] for row in corrections}
                report["persistence"] = {
                    "actualFaceContainerRestarts": 2,
                    "namesAndAliases": True,
                    "merge": True,
                    "undoMerge": True,
                    "split": True,
                    "stableFaceIds": True,
                }
                print("PASS: labels/aliases, reversible merge, undo and split survive actual face-container restarts")

                group = str(uuid.uuid4())
                pending = [
                    upload(owner, library, uploads, data, "compound-" + fixture["id"] + ".jpg", resource_set=group)
                    for fixture, data in zip(fixtures[:2], originals[:2])
                ]
                for item in pending:
                    request(API + "/v1/faces/jobs/" + item["id"], token=owner, method="POST", expected=404)
                assert not {p["id"] for p in pending} & {job["assetId"] for job in page_all("/v1/faces/jobs", owner)}
                resources = [
                    {
                        "assetId": p["id"],
                        "sha256": p["sha256"],
                        "size": p["size"],
                        "fileName": p["fileName"],
                        "role": "photo" if i == 0 else "alternatePhoto",
                        "uniformTypeIdentifier": "public.jpeg",
                    }
                    for i, p in enumerate(pending)
                ]
                request(
                    API + f"/v1/libraries/{library}/resource-sets/{group}",
                    token=owner,
                    method="PUT",
                    data={
                        "kind": "edited",
                        "sourceRevision": "face-source-authorization-fixture",
                        "primaryAssetId": pending[0]["id"],
                        "resources": resources,
                    },
                )
                automatic_jobs(owner, pending[:1])
                request(API + "/v1/faces/jobs/" + pending[1]["id"], token=owner, method="POST", expected=404)
                assert pending[1]["id"] not in {job["assetId"] for job in page_all("/v1/faces/jobs", owner)}
                smoke.sql(
                    "DELETE FROM library_members WHERE subject=:'subject' AND library_id=:'library'::uuid;",
                    subject=owner_id,
                    library=library,
                )
                try:
                    request(API + "/v1/faces/jobs/" + assets[0]["id"], token=owner, method="POST", expected=404)
                    assert page_all("/v1/faces/observations?assetId=" + assets[0]["id"], owner) == []
                finally:
                    smoke.sql(
                        "INSERT INTO library_members(subject,library_id) VALUES(:'subject',:'library'::uuid) ON CONFLICT DO NOTHING;",
                        subject=owner_id,
                        library=library,
                    )
                # This outage is restricted to the optional face ingress. Media,
                # identity, broker and base Library/Storage processes keep running.
                subprocess.run(COMPOSE + ["stop", "faces-api"], cwd=ROOT, check=True, capture_output=True, timeout=30)
                try:
                    no_face = upload(owner, library, uploads, blank_png(), "blank-no-face.png", "image/png")
                    smoke.wait(
                        "Library durably records failed face delivery while originals stay available",
                        lambda: publication_retry_recorded(no_face["id"]),
                        timeout=45,
                    )
                finally:
                    subprocess.run(
                        COMPOSE + ["start", "faces-api"], cwd=ROOT, check=True, capture_output=True, timeout=30
                    )
                smoke.wait(
                    "optional face ingress recovers", lambda: request(API + "/v1/faces/jobs?limit=1", token=owner)
                )
                automatic_jobs(owner, [no_face], expected_status="no_faces")
                assert page_all("/v1/faces/observations?assetId=" + no_face["id"], owner) == []
                report["sourceAuthorization"] = {
                    "pendingRejected": True,
                    "hiddenCompanionRejected": True,
                    "committedPrimaryAutomaticallyAnalyzed": True,
                    "liveMembershipRequired": True,
                    "realBlankImageNoFaces": True,
                }
                report["faceIngressOutage"] = {
                    "originalUploadAndRetrievalUnaffected": True,
                    "durableRetryObserved": True,
                    "automaticallyRecovered": True,
                }
                print(
                    "PASS: pending/hidden-companion and revoked-membership denial; committed primary indexing; actual no-face handling"
                )

                admin_access(owner_id, False)
                disabled = True
                request(API + "/v1/analysis/access", token=owner, expected=403)
                for path in (
                    "/people",
                    "/jobs",
                    "/observations",
                    "/corrections",
                    f"/people/{primary}",
                    f"/people/{primary}/assets",
                    "/jobs/" + jobs[0]["id"],
                ):
                    request(API + "/v1/faces" + path, token=owner, expected=403)
                request(API + "/v1/faces/jobs/" + assets[0]["id"], token=owner, method="POST", expected=403)
                request(
                    API + f"/v1/faces/people/{primary}/name",
                    token=owner,
                    method="PUT",
                    data={"name": "Forbidden after disablement", "aliases": []},
                    expected=403,
                )
                request(API + "/v1/assets/" + assets[0]["id"] + "/original", token=reader, expected=404)
                assert face_for(reader, independent["id"])["personId"] == private_person
                report["disabledExistingJwtDenied"] = True
                admin_access(owner_id, True)
                disabled = False
                assert media["raw"]("/v1/assets/" + assets[0]["id"] + "/original", owner)[0] == originals[0]
                report["originalUnmodifiedAfterAnalysisAndCorrections"] = True
                report["status"] = "passed"
                print(
                    "PASS: private-admin disablement immediately denies existing JWTs; independent owner remains isolated"
                )
            finally:
                try:
                    if disabled:
                        admin_access(owner_id, True)
                    if share_id:
                        request(API + "/v1/shares/" + share_id, token=owner, method="DELETE", expected=204)
                finally:
                    for subject in subjects:
                        cleanup_faces(subject)
    except Exception as error:
        report["status"] = "failed"
        report["error"] = str(error)
        raise
    finally:
        report["seconds"] = round(time.monotonic() - started, 2)
        REPORT.write_text(json.dumps(report, indent=2) + "\n")
    print("Real-stack face acceptance passed; fixture users, media and biometric annotations cleaned up.")
    print("Evidence:", REPORT.relative_to(ROOT))
    print("Six portrait similarities:", json.dumps(report["similarities"]["matrix"]))


if __name__ == "__main__":
    main()
