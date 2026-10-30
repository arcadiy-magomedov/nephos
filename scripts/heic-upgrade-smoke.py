#!/usr/bin/env python3
"""Verify HEIC upgrade/backfill in a disposable Library database, never live tables."""

from pathlib import Path
import subprocess
import uuid

ROOT = Path(__file__).resolve().parents[1]
MIGRATIONS = ROOT / "src/Nephos.Migrations/Sql/library"


def sql(database, statement):
    return subprocess.check_output(
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
            database,
            "-v",
            "ON_ERROR_STOP=1",
            "-Atq",
        ],
        input=statement,
        text=True,
        cwd=ROOT,
        stderr=subprocess.PIPE,
    ).strip()


def main():
    database = "heic_upgrade_" + uuid.uuid4().hex
    sql("postgres", f"CREATE DATABASE {database} OWNER library_owner;")
    try:
        sql("postgres", f"REVOKE CONNECT ON DATABASE {database} FROM PUBLIC;")
        previous = sorted(path for path in MIGRATIONS.glob("*.sql") if path.name < "006_")
        sql(
            database,
            "SET ROLE library_owner; REVOKE ALL ON SCHEMA public FROM PUBLIC;"
            "GRANT USAGE ON SCHEMA public TO library_app;\n" + "\n".join(path.read_text() for path in previous),
        )
        sql(
            database,
            """
            INSERT INTO principals(subject,enabled) VALUES('owner',true),('disabled',false),('nonmember',true);
            INSERT INTO libraries(id,name) VALUES('00000000-0000-0000-0000-000000000001','Upgrade fixture');
            INSERT INTO library_members(subject,library_id)
                SELECT subject,'00000000-0000-0000-0000-000000000001' FROM principals WHERE subject<>'nonmember';
            INSERT INTO assets(id,library_id,uploaded_by,file_name,media_type,size,sha256,has_preview,created_at,
                hidden,pending_resource_set_id,resource_set_id)
            SELECT lpad(n::text,32,'0')::uuid,'00000000-0000-0000-0000-000000000001',
                CASE n WHEN 7 THEN 'disabled' WHEN 8 THEN 'nonmember' ELSE 'owner' END,
                'fixture.heic',CASE n WHEN 2 THEN 'image/heif' WHEN 3 THEN 'image/jpeg'
                    WHEN 11 THEN 'image/heic-sequence' ELSE 'image/heic' END,
                CASE n WHEN 6 THEN 20971521 ELSE 1024 END,repeat('a',64),false,now(),
                n IN (4,10),
                CASE WHEN n IN (5,9,10) THEN '00000000-0000-0000-0000-000000000099'::uuid END,
                CASE WHEN n IN (9,10) THEN '00000000-0000-0000-0000-000000000099'::uuid END
            FROM generate_series(1,11) AS n;
            INSERT INTO resource_sets(id,library_id,subject,primary_asset_id,manifest)
                VALUES('00000000-0000-0000-0000-000000000099','00000000-0000-0000-0000-000000000001',
                'owner','00000000-0000-0000-0000-000000000009','{"resources":[]}');
            INSERT INTO face_publications(asset_id,delivered_at,last_status,lease_id,lease_until)
                VALUES('00000000-0000-0000-0000-000000000001',now(),404,
                    '00000000-0000-0000-0000-000000000088',now()+interval '1 hour'),
                ('00000000-0000-0000-0000-000000000003',now(),202,NULL,NULL);
            """,
        )
        assert sql(database, "SET ROLE library_app; SELECT id FROM analysis_sources ORDER BY id;").splitlines() == [
            "00000000-0000-0000-0000-000000000003"
        ]
        upgrade = (MIGRATIONS / "006_heic_face_sources.sql").read_text()
        for _ in range(2):
            sql(database, "SET ROLE library_owner;\n" + upgrade)
            assert sql(database, "SET ROLE library_app; SELECT id FROM analysis_sources ORDER BY id;").splitlines() == [
                f"00000000-0000-0000-0000-{number:012d}" for number in (1, 2, 3, 9)
            ]
            assert sql(
                database,
                """
                SET ROLE library_app;
                SELECT count(*) FROM face_publications WHERE delivered_at IS NULL
                    AND lease_id IS NULL AND lease_until IS NULL AND attempts=0 AND last_status IS NULL;
                SELECT count(*) FROM face_publications;
                SELECT count(*) FROM face_publications WHERE last_status=202 AND delivered_at IS NOT NULL;
                """,
            ).splitlines() == ["3", "4", "1"]
        sql(database, "UPDATE principals SET enabled=false WHERE subject='owner';")
        assert sql(database, "SET ROLE library_app; SELECT count(*) FROM analysis_sources;") == "0"
        print(
            "PASS: HEIC/HEIF upgrade preserves runtime grants, backfills existing primaries idempotently, "
            "resets stale leases and excludes hidden/pending/disabled/nonmember/oversized/sequence assets"
        )
    finally:
        sql("postgres", f"DROP DATABASE {database};")


if __name__ == "__main__":
    main()
