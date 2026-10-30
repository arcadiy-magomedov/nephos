#!/usr/bin/env python3
"""Requeue eligible committed primary photos; safe to repeat after enabling faces or changing models."""

import json
from pathlib import Path
import subprocess
import uuid

ROOT = Path(__file__).resolve().parents[1]


def main():
    cursor = uuid.UUID(int=0)
    total = 0
    while True:
        # UUID parsing above/below fences the only interpolated SQL value.
        statement = f"""
            WITH batch AS (
                SELECT id FROM analysis_sources WHERE id>'{cursor}'::uuid ORDER BY id LIMIT 500
            ), queued AS (
                INSERT INTO face_publications(asset_id) SELECT id FROM batch
                ON CONFLICT(asset_id) DO UPDATE SET delivered_at=NULL,next_attempt_at=now(),
                    attempts=0,lease_id=NULL,lease_until=NULL,last_status=NULL
                RETURNING asset_id
            )
            SELECT json_build_object('count',(SELECT count(*) FROM queued),
                'last',(SELECT id FROM batch ORDER BY id DESC LIMIT 1));
        """
        output = subprocess.check_output(
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
                "-Atc",
                statement,
            ],
            cwd=ROOT,
            text=True,
        )
        result = json.loads(output)
        total += result["count"]
        if result["last"] is None:
            break
        cursor = uuid.UUID(result["last"])
    print(f"Queued {total} eligible primary photos for idempotent face analysis.")


if __name__ == "__main__":
    main()
