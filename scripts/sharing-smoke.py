#!/usr/bin/env python3
"""Verify selected/all-media sharing through real authorization, snapshot and original APIs."""

import runpy
import secrets
import uuid

import smoke

release = runpy.run_path(str(smoke.ROOT / "scripts/release-smoke.py"))
media = release["media"]
request, API = smoke.request, smoke.API


def main():
    smoke.wait("sharing API ready", lambda: request(API + "/health/library") == "Healthy")
    with (
        media["account"]() as (owner, owner_id, library, uploads),
        media["account"]() as (recipient, recipient_id, _, _),
        media["account"]() as (outsider, _, _, _),
    ):
        smoke.sql(
            """
            UPDATE principals SET display_name='Owner',discoverable=true WHERE subject=:'owner';
            UPDATE principals SET display_name='Recipient',discoverable=true WHERE subject=:'recipient';
            """,
            owner=owner_id,
            recipient=recipient_id,
        )
        directory = request(API + "/v1/users", token=owner)
        assert any(person["id"] == recipient_id and person["name"] == "Recipient" for person in directory["items"])
        first = release["upload"](owner, library, uploads, secrets.token_bytes(128))
        private = release["upload"](owner, library, uploads, secrets.token_bytes(128))
        share_id = str(uuid.uuid4())
        definition = {
            "libraryId": library,
            "recipientId": recipient_id,
            "allAssets": False,
            "assetIds": [first["assetId"]],
        }
        share = request(API + "/v1/shares/" + share_id, token=owner, method="PUT", data=definition)
        assert share["assetIds"] == [first["assetId"]] and share["ownerName"] == "Owner"
        request(API + "/v1/shares/" + share_id, token=outsider, method="PUT", data=definition, expected=404)
        shared_library = next(
            row for row in request(API + "/v1/libraries", token=recipient)["items"] if row["id"] == library
        )
        assert shared_library["isShared"]
        prefix = API + "/v1/libraries/" + library
        snapshot = request(prefix + "/snapshots", token=recipient, method="POST")
        assert snapshot["totalCount"] == 1
        page = request(prefix + "/snapshots/" + snapshot["id"] + "/assets", token=recipient)
        assert [row["id"] for row in page["items"]] == [first["assetId"]]
        assert page["items"][0]["sharedBy"] == "Owner"
        assert len(media["raw"]("/v1/assets/" + first["assetId"] + "/original", recipient)[0]) == 128
        request(API + "/v1/assets/" + private["assetId"] + "/original", token=recipient, expected=404)
        request(API + "/v1/assets/" + first["assetId"] + "/retention", token=recipient, method="POST", expected=404)
        request(prefix + "?upload=true", token=recipient, expected=404)
        request(
            API + "/v1/uploads",
            token=recipient,
            data={
                "id": str(uuid.uuid4()),
                "libraryId": library,
                "fileName": first["fileName"],
                "mediaType": "application/octet-stream",
                "sha256": first["sha256"],
                "size": first["size"],
            },
            expected=403,
        )
        request(
            API + "/v1/shares/" + share_id,
            token=owner,
            method="PUT",
            data={**definition, "allAssets": True, "assetIds": []},
        )
        request(prefix + "/snapshots/" + snapshot["id"] + "/assets", token=recipient, expected=410)
        all_snapshot = request(prefix + "/snapshots", token=recipient, method="POST")
        assert all_snapshot["totalCount"] == 2
        new_asset = release["upload"](owner, library, uploads, secrets.token_bytes(32))
        target = request(prefix + "/snapshots", token=recipient, method="POST")
        delta = request(
            prefix + f"/changes?after={all_snapshot['revision']}&through={target['revision']}", token=recipient
        )
        assert [c["assetId"] for change in delta["changes"] for c in change["items"]] == [new_asset["assetId"]]
        assert request(prefix + "/snapshots/" + all_snapshot["id"] + "/assets", token=recipient)["items"] != []
        request(API + "/v1/shares/" + share_id, token=outsider, method="DELETE", expected=404)
        request(API + "/v1/shares/" + share_id, token=owner, method="DELETE", expected=204)
        request(prefix + "/snapshots/" + target["id"] + "/assets", token=recipient, expected=404)
        request(API + "/v1/assets/" + first["assetId"] + "/original", token=recipient, expected=404)

        group_id = str(uuid.uuid4())
        parts = [release["upload"](owner, library, uploads, secrets.token_bytes(64), group_id) for _ in range(2)]
        request(
            prefix + "/resource-sets/" + group_id,
            token=owner,
            method="PUT",
            data={
                "kind": "archive",
                "sourceRevision": "sharing-fixture",
                "primaryAssetId": parts[0]["assetId"],
                "resources": parts,
            },
        )
        request(
            API + "/v1/shares/" + share_id,
            token=owner,
            method="PUT",
            data={**definition, "assetIds": [parts[0]["assetId"]]},
        )
        assert len(request(API + "/v1/resource-sets/" + group_id, token=recipient)["resources"]) == 2
        assert len(media["raw"]("/v1/assets/" + parts[1]["assetId"] + "/original", recipient)[0]) == 64
        request(API + "/v1/resource-sets/" + group_id + "/retention", token=recipient, method="POST", expected=404)
        with smoke.AdminSession() as admin:
            admin.submit({"action": "access", "subject": owner_id})
        request(API + "/v1/assets/" + parts[0]["assetId"] + "/original", token=recipient, expected=404)
        request(API + "/v1/users", token=owner, expected=403)
        print(
            "PASS: known directory, selected/all/future media, frozen scoped views/deltas, compound originals, provenance, read-only authority and revocation"
        )


if __name__ == "__main__":
    main()
