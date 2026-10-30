#!/usr/bin/env python3
"""Cold-restore a real pending media publication without exposing restored services."""

import importlib.util
from pathlib import Path
import secrets
import shutil
import runpy
import uuid

import backup
import smoke

spec = importlib.util.spec_from_file_location("media_smoke", Path(__file__).with_name("media-smoke.py"))
media = importlib.util.module_from_spec(spec)
spec.loader.exec_module(media)
release = runpy.run_path(str(smoke.ROOT / "scripts/release-smoke.py"))
destination = smoke.ROOT / "artifacts" / ("restore-smoke-" + uuid.uuid4().hex)

try:
    with media.account() as (token, _, library, uploads):
        set_id = str(uuid.uuid4())
        resources = [release["upload"](token, library, uploads, secrets.token_bytes(128), set_id) for _ in range(2)]
        smoke.request(
            smoke.API + f"/v1/libraries/{library}/resource-sets/{set_id}",
            token=token,
            method="PUT",
            data={
                "kind": "archive",
                "sourceRevision": "restore-fixture",
                "primaryAssetId": resources[0]["assetId"],
                "resources": resources,
            },
        )
        snapshot = smoke.request(smoke.API + f"/v1/libraries/{library}/snapshots", token=token, method="POST")
        assert snapshot["totalCount"] == 1
        data = secrets.token_bytes(4096)
        _, status = media.intent(token, library, uploads, data)
        identifier = status["id"]
        media.raw("/v1/uploads/" + identifier + "/parts/0", token, data, "PUT", 204)
        media.compose("stop", "library-worker")
        try:
            smoke.request(
                smoke.API + "/v1/uploads/" + identifier + "/complete", token=token, method="POST", expected=202
            )

            def queued():
                value = backup.run(
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
                    "SELECT sent_at IS NOT NULL FROM outbox WHERE id='" + identifier + "'",
                )
                return value == "t"

            smoke.wait("verified publication durably queued before snapshot", queued)
            backup.create(destination)
            backup.verify_restore(destination, expected_queued=1, expected_sets=1, expected_snapshots=1)
        finally:
            media.compose("start", "library-worker")
        smoke.wait(
            "source stack recovers after cold snapshot",
            lambda: smoke.request(smoke.API + "/health/storage") == "Healthy",
        )
        media.ready(token, identifier)
        assert media.raw("/v1/assets/" + identifier + "/original", token)[0] == data
        assert smoke.request(smoke.API + "/v1/resource-sets/" + set_id, token=token)["resources"] == resources
        restored_page = smoke.request(
            smoke.API + f"/v1/libraries/{library}/snapshots/{snapshot['id']}/assets", token=token
        )
        assert [asset["id"] for asset in restored_page["items"]] == [resources[0]["assetId"]]
        print(
            "PASS: cold snapshot restores originals, complete manifests, frozen gallery views and pending publication; source resumes normally"
        )
finally:
    if destination.exists():
        shutil.rmtree(destination)
