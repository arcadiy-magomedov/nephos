#!/usr/bin/env python3
"""Compound manifests, immutable gallery views, and atomic catch-up against real services."""

import hashlib
import runpy
import secrets
import uuid

import smoke

media = runpy.run_path(str(smoke.ROOT / "scripts" / "media-smoke.py"))
request = smoke.request
API = smoke.API


def upload(token, library, uploads, body, set_id=None, filename="original.bin"):
    identifier = str(uuid.uuid4())
    uploads.append(identifier)
    intent = {
        "id": identifier,
        "libraryId": library,
        "fileName": filename,
        "mediaType": "application/octet-stream",
        "size": len(body),
        "sha256": hashlib.sha256(body).hexdigest(),
        "capturedAt": "2020-05-06T12:00:00Z",
    }
    if set_id:
        intent["resourceSetId"] = set_id
    status = request(API + "/v1/uploads", token=token, data=intent)
    if status["state"] == "uploading":
        media["raw"]("/v1/uploads/" + status["id"] + "/parts/0", token, body, "PUT", 204)
        request(API + "/v1/uploads/" + status["id"] + "/complete", token=token, method="POST", expected=202)
    media["ready"](token, status["id"])
    return {
        "assetId": status["id"],
        "sha256": intent["sha256"],
        "size": len(body),
        "fileName": filename,
        "role": "photo",
        "uniformTypeIdentifier": "public.data",
    }


def main():
    smoke.wait("media services ready", lambda: request(API + "/health/storage") == "Healthy")
    smoke.wait("identity ready", lambda: request(smoke.IDENTITY + "/realms/nephos/.well-known/openid-configuration"))
    with (
        media["account"]() as (token, subject, library, uploads),
        media["account"]() as (other, other_subject, other_library, other_uploads),
    ):
        prefix = API + "/v1/libraries/" + library
        initial = request(prefix + "/snapshots", token=token, method="POST")
        assert initial["totalCount"] == 0
        original = secrets.token_bytes(128)
        legacy = upload(token, library, uploads, original)
        before = request(prefix + "/snapshots", token=token, method="POST")
        assert before["totalCount"] == 1
        set_id = str(uuid.uuid4())
        primary = upload(token, library, uploads, original, set_id)
        assert primary["assetId"] != legacy["assetId"], "Compound references must not alias an unrelated logical asset"
        assert request(prefix + "/snapshots", token=token, method="POST")["revision"] == before["revision"]
        second = {**primary, "assetId": str(uuid.uuid4()), "role": "pairedVideo"}
        manifest = {
            "kind": "live-photo",
            "sourceRevision": "fixture-revision-1",
            "primaryAssetId": primary["assetId"],
            "resources": [primary, second],
        }
        endpoint = prefix + "/resource-sets/" + set_id
        request(endpoint, token=token, method="PUT", data=manifest, expected=409)
        request(API + "/v1/resource-sets/" + set_id, token=token, expected=404)
        second = upload(token, library, uploads, secrets.token_bytes(96), set_id, "paired.mov")
        second["role"] = "pairedVideo"
        second["uniformTypeIdentifier"] = "com.apple.quicktime-movie"
        manifest["resources"] = [primary, second]
        foreign = upload(other, other_library, other_uploads, secrets.token_bytes(64))
        request(
            endpoint,
            token=token,
            method="PUT",
            data={**manifest, "kind": "archive", "resources": [primary, foreign]},
            expected=409,
        )
        request(
            endpoint,
            token=token,
            method="PUT",
            data={**manifest, "resources": [primary, {**second, "sha256": "0" * 64}]},
            expected=409,
        )
        committed = request(endpoint, token=token, method="PUT", data=manifest)
        assert committed["resources"] == manifest["resources"]
        assert request(endpoint, token=token, method="PUT", data=manifest) == committed
        request(endpoint, token=token, method="PUT", data={**manifest, "sourceRevision": "changed"}, expected=409)
        request(API + "/v1/resource-sets/" + set_id, token=other, expected=404)
        assert request(API + "/v1/assets/" + primary["assetId"] + "/resources", token=token) == committed

        after = request(prefix + "/snapshots", token=token, method="POST")
        assert after["totalCount"] == 2 and after["revision"] == before["revision"] + 1
        old_page = request(prefix + "/snapshots/" + before["id"] + "/assets", token=token)
        assert [a["id"] for a in old_page["items"]] == [legacy["assetId"]]
        current_page = request(prefix + "/snapshots/" + after["id"] + "/assets", token=token)
        assert {a["id"] for a in current_page["items"]} == {legacy["assetId"], primary["assetId"]}
        assert next(a for a in current_page["items"] if a["id"] == primary["assetId"])["resourceSetId"] == set_id
        delta = request(
            prefix + f"/changes?after={before['revision']}&through={after['revision']}&limit=1", token=token
        )
        assert delta["toRevision"] == after["revision"] and not delta["hasMore"] and len(delta["changes"]) == 1
        assert {(c["operation"], c["assetId"]) for c in delta["changes"][0]["items"]} == {
            ("upsert", primary["assetId"]),
            ("remove", second["assetId"]),
        }
        counts = request(prefix + "/snapshots/" + before["id"] + "/timeline?year=2020&month=5", token=token)
        assert counts["items"] == [{"date": "2020-05-06", "count": 1}]
        hold = request(API + "/v1/resource-sets/" + set_id + "/retention", token=token, method="POST")
        assert {r["id"] for r in hold["resources"]} == {primary["assetId"], second["assetId"]}
        assert all(r["available"] and r["holdId"] for r in hold["resources"])
        request(API + "/v1/resource-sets/" + set_id + "/retention", token=other, method="POST", expected=404)
        original_path = "/data/media/blobs/" + second["sha256"][:2] + "/" + second["sha256"]
        missing_path = original_path + ".release-smoke"
        media["compose"]("exec", "-T", "storage-api", "mv", "--", original_path, missing_path)
        try:
            request(API + "/v1/resource-sets/" + set_id + "/retention", token=token, method="POST", expected=503)
        finally:
            media["compose"]("exec", "-T", "storage-api", "mv", "--", missing_path, original_path)
        print(
            "PASS: incomplete compounds hidden; immutable complete manifest, all-resource retention and one atomic gallery transition"
        )

        for _ in range(3):
            upload(token, library, uploads, secrets.token_bytes(32))
        target = request(prefix + "/snapshots", token=token, method="POST")
        upload(token, library, uploads, secrets.token_bytes(32))
        cursor = after["revision"]
        revisions = []
        while cursor < target["revision"]:
            page = request(prefix + f"/changes?after={cursor}&through={target['revision']}&limit=1", token=token)
            assert page["fromRevision"] == cursor and len(page["changes"]) == 1
            revisions.extend(change["revision"] for change in page["changes"])
            cursor = page["toRevision"]
        assert revisions == list(range(after["revision"] + 1, target["revision"] + 1))
        assert request(prefix + "/snapshots/" + after["id"] + "/assets", token=token) == current_page
        request(prefix + "/snapshots/" + after["id"] + "/assets", token=other, expected=404)
        smoke.sql(
            "INSERT INTO library_members(subject,library_id) VALUES(:'subject',:'library'::uuid);",
            subject=other_subject,
            library=library,
        )
        request(prefix + "/snapshots/" + after["id"] + "/assets", token=other, expected=410)
        assert media["raw"]("/v1/assets/" + primary["assetId"] + "/original", other)[0] == original
        request(API + "/v1/assets/" + primary["assetId"] + "/retention", token=other, method="POST", expected=404)
        request(API + "/v1/resource-sets/" + set_id + "/retention", token=other, method="POST", expected=404)
        smoke.sql(
            "UPDATE principals SET access_generation=access_generation+1 WHERE subject=:'subject';", subject=subject
        )
        request(prefix + "/snapshots/" + after["id"] + "/assets", token=token, expected=410)
        request(prefix + f"/changes?after={after['revision']}&through={target['revision']}", token=token, expected=410)
        refreshed = request(prefix + "/snapshots", token=token, method="POST")
        assert refreshed["accessGeneration"] == after["accessGeneration"] + 1
        smoke.sql(
            "UPDATE gallery_snapshots SET expires_at=now()-interval '1 second' WHERE id=:'id'::uuid;",
            id=refreshed["id"],
        )
        request(prefix + "/snapshots/" + refreshed["id"] + "/assets", token=token, expected=410)
        print(
            "PASS: retained pages/counts, fixed-target paged deltas, concurrent arrivals, account isolation, generation fencing and expiry"
        )
    print(
        "Release gallery/resource-set acceptance passed. Synthetic compound bytes test protocol completeness, not PhotoKit restoration."
    )


if __name__ == "__main__":
    main()
