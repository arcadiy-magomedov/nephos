#!/usr/bin/env python3
"""Cold and zero-downtime online backups with isolated restore verification; never overwrite an existing volume."""

import argparse
import hashlib
import json
import os
import re
import secrets
import subprocess
import tarfile
import time
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
VOLUMES = ("postgres", "media", "rabbitmq")
BASE_DATABASES = ("library", "storage", "keycloak")
FACES_VOLUME = "faces-postgres"
FACES_DATABASE = "faces"
MEDIA_BLOBS_ARCHIVE = "media-blobs.tar"

LIBRARY_INTEGRITY_SQL = """
SELECT
  (SELECT count(*) FROM resource_sets),
  (SELECT count(*) FROM gallery_snapshots),
  (SELECT count(*) FROM resource_sets s
   CROSS JOIN LATERAL jsonb_array_elements(s.manifest->'resources') r
   LEFT JOIN assets a ON a.id=(r->>'assetId')::uuid
   WHERE a.id IS NULL OR a.library_id<>s.library_id OR a.uploaded_by<>s.subject
     OR a.resource_set_id IS DISTINCT FROM s.id
     OR a.sha256 IS DISTINCT FROM r->>'sha256' OR a.size<>(r->>'size')::bigint
     OR a.file_name IS DISTINCT FROM r->>'fileName' OR a.hidden<>(a.id<>s.primary_asset_id)),
  (SELECT count(*) FROM gallery_snapshots s JOIN principals p ON p.subject=s.subject
   WHERE p.enabled AND s.access_generation=p.access_generation+p.share_generation
     AND can_read_library(s.subject,s.library_id) AND s.total_count<>(
    SELECT count(*) FROM gallery_versions v WHERE v.library_id=s.library_id AND v.visible
      AND can_read_asset(s.subject,v.asset_id)
      AND v.from_revision<=s.revision AND (v.to_revision IS NULL OR v.to_revision>s.revision)));
"""

LIVE_BLOBS_SQL = (
    "SELECT b.sha256,b.size FROM blobs b "
    "WHERE EXISTS(SELECT 1 FROM blob_references r WHERE r.sha256=b.sha256) "
    "OR EXISTS(SELECT 1 FROM retention_holds h JOIN uploads u ON u.id=h.asset_id "
    "WHERE u.sha256=b.sha256 AND h.retained_until>now()) "
    "OR EXISTS(SELECT 1 FROM outbox o JOIN uploads u ON u.id=o.id "
    "WHERE u.sha256=b.sha256 AND o.sent_at IS NULL)"
)

ONLINE_RESTORE_RECONCILE_SQL = """
BEGIN;
DELETE FROM upload_parts;
UPDATE uploads
SET state = 'failed',
    error = 'Interrupted by online backup restore; retry upload.',
    staging_cleaned = true,
    updated_at = now()
WHERE state IN ('uploading', 'verifying');
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'uploads' AND column_name = 'verify_lease_id'
    ) THEN
        UPDATE uploads
        SET verify_lease_id = NULL,
            verify_lease_until = NULL
        WHERE verify_lease_id IS NOT NULL OR verify_lease_until IS NOT NULL;
    END IF;
END $$;
COMMIT;
"""

CREATE_POSTGRES_ROLE_RE = re.compile(r'^CREATE ROLE (?:"?postgres"?);$')
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")


def run(*args):
    return subprocess.check_output(args, cwd=ROOT, text=True, stderr=subprocess.PIPE).strip()


def run_stdin(command, *, input_bytes=None, stdin_file=None):
    return subprocess.run(
        command,
        input=input_bytes,
        stdin=stdin_file,
        capture_output=True,
        cwd=ROOT,
        check=True,
    )


def digest(path):
    result = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            result.update(block)
    return result.hexdigest()


def copy_private_file(source, destination):
    with source.open("rb") as src, destination.open("xb") as dst:
        os.fchmod(dst.fileno(), 0o600)
        for block in iter(lambda: src.read(1024 * 1024), b""):
            dst.write(block)
        dst.flush()
        os.fsync(dst.fileno())


def write_private_json(destination, payload):
    with destination.open("x", encoding="utf-8") as output:
        os.fchmod(output.fileno(), 0o600)
        json.dump(payload, output, indent=2)
        output.flush()
        os.fsync(output.fileno())


def stream_to_private_file(command, destination):
    # Stream through the host process so private backup files are always caller-owned and mode 0600.
    with destination.open("xb") as output:
        os.fchmod(output.fileno(), 0o600)
        subprocess.run(
            command,
            stdout=output,
            stderr=subprocess.PIPE,
            cwd=ROOT,
            check=True,
        )
        output.flush()
        os.fsync(output.fileno())


def _safe_backup_file(path, filename):
    if not isinstance(filename, str) or not filename or Path(filename).name != filename or filename in (".", ".."):
        raise ValueError(f"Unsafe backup file name: {filename!r}")
    candidate = path / filename
    if not candidate.is_file():
        raise ValueError(f"Missing backup file: {filename}")
    return candidate


def _verify_file_entry(path, label, entry):
    if not isinstance(entry, dict) or not isinstance(entry.get("sha256"), str):
        raise ValueError(f"Invalid manifest entry: {label}")
    target = _safe_backup_file(path, entry.get("file"))
    if digest(target) != entry["sha256"]:
        raise ValueError(f"Checksum mismatch: {label}")


def verify_manifest(path):
    manifest = json.loads((path / "manifest.json").read_text())
    if not isinstance(manifest, dict):
        raise ValueError("Unsupported or incomplete backup manifest.")
    fmt = manifest.get("format")
    if fmt == 1:
        archives = manifest.get("archives")
        if not isinstance(archives, dict) or set(archives) != set(VOLUMES):
            raise ValueError("Unsupported or incomplete backup manifest.")
        for name in VOLUMES:
            archive_path = _safe_backup_file(path, name + ".tar")
            if digest(archive_path) != archives[name]:
                raise ValueError("Archive checksum mismatch: " + name)
        env_path = _safe_backup_file(path, ".env")
        if digest(env_path) != manifest.get("credentialsChecksum"):
            raise ValueError("Credential file checksum mismatch.")
        if "faces" in manifest:
            faces = manifest["faces"]
            if (
                not isinstance(faces, dict)
                or not isinstance(faces.get("image"), str)
                or not faces["image"]
                or not isinstance(faces.get("archiveChecksum"), str)
                or not isinstance(faces.get("credentialsChecksum"), str)
            ):
                raise ValueError("Invalid faces metadata in backup manifest.")
            faces_archive = _safe_backup_file(path, faces.get("archive"))
            if digest(faces_archive) != faces["archiveChecksum"]:
                raise ValueError("Archive checksum mismatch: faces-postgres")
            faces_env = _safe_backup_file(path, ".env.faces")
            if digest(faces_env) != faces["credentialsChecksum"]:
                raise ValueError("Faces credential file checksum mismatch.")
        return manifest
    if fmt == 2:
        if manifest.get("mode") != "online" or not isinstance(manifest.get("hasFaces"), bool):
            raise ValueError("Unsupported or incomplete v2 backup manifest.")
        has_faces = manifest["hasFaces"]
        images = manifest.get("images")
        if not isinstance(images, dict) or not isinstance(images.get("postgres"), str) or not images["postgres"]:
            raise ValueError("Missing postgres image in v2 backup manifest.")
        if has_faces and (not isinstance(images.get("facesPostgres"), str) or not images["facesPostgres"]):
            raise ValueError("Missing facesPostgres image in v2 backup manifest.")
        expected_globals = {"postgres", "faces"} if has_faces else {"postgres"}
        globals_map = manifest.get("globals")
        if not isinstance(globals_map, dict) or set(globals_map) != expected_globals:
            raise ValueError("Incomplete globals entries in v2 backup manifest.")
        for key in sorted(expected_globals):
            _verify_file_entry(path, f"globals.{key}", globals_map[key])
        expected_dbs = set(BASE_DATABASES) | ({FACES_DATABASE} if has_faces else set())
        databases = manifest.get("databases")
        if not isinstance(databases, dict) or set(databases) != expected_dbs:
            raise ValueError("Incomplete database entries in v2 backup manifest.")
        for key in sorted(expected_dbs):
            _verify_file_entry(path, f"databases.{key}", databases[key])
        _verify_file_entry(path, "mediaBlobs", manifest.get("mediaBlobs"))
        env_path = _safe_backup_file(path, ".env")
        if digest(env_path) != manifest.get("credentialsChecksum"):
            raise ValueError("Credential file checksum mismatch.")
        if has_faces:
            expected_faces_cred = manifest.get("facesCredentialsChecksum")
            if not isinstance(expected_faces_cred, str) or not expected_faces_cred:
                raise ValueError("Missing facesCredentialsChecksum in v2 backup manifest.")
            faces_env = _safe_backup_file(path, ".env.faces")
            if digest(faces_env) != expected_faces_cred:
                raise ValueError("Faces credential file checksum mismatch.")
        elif "facesCredentialsChecksum" in manifest:
            raise ValueError("Unexpected facesCredentialsChecksum when hasFaces is false.")
        return manifest
    raise ValueError("Unsupported or incomplete backup manifest.")


def export_volume(volume, destination):
    # Docker needs root to read database files; the host must own the archive.
    stream_to_private_file(
        [
            "docker",
            "run",
            "--rm",
            "--network",
            "none",
            "-v",
            volume + ":/source:ro",
            "alpine:3.23",
            "tar",
            "-cf",
            "-",
            "-C",
            "/source",
            ".",
        ],
        destination,
    )


def export_media_blobs(volume, destination):
    # Exclude rebuildable previews and in-flight staging; keep /data/media ownership intact.
    stream_to_private_file(
        [
            "docker",
            "run",
            "--rm",
            "--network",
            "none",
            "-v",
            volume + ":/source:ro",
            "alpine:3.23",
            "tar",
            "-cf",
            "-",
            "--exclude=media/previews",
            "--exclude=media/staging",
            "-C",
            "/source",
            "media",
        ],
        destination,
    )


def dump_globals(compose_cmd, service, destination):
    stream_to_private_file(
        [*compose_cmd, "exec", "-T", service, "pg_dumpall", "-U", "postgres", "--globals-only"],
        destination,
    )


def dump_database(compose_cmd, service, database, destination):
    stream_to_private_file(
        [
            *compose_cmd,
            "exec",
            "-T",
            service,
            "pg_dump",
            "-U",
            "postgres",
            "--format=custom",
            "--create",
            "-d",
            database,
        ],
        destination,
    )


def detect_faces(config, active, source_env, faces_env):
    if not faces_env.is_file():
        return None
    if FACES_VOLUME in config.get("services", {}):
        if FACES_VOLUME not in active:
            return None
        return {
            "compose": ["docker", "compose"],
            "services": [],
            "volume": config["volumes"][FACES_VOLUME]["name"],
            "image": config["services"][FACES_VOLUME]["image"],
            "env_file": faces_env,
        }
    if not (ROOT / "compose.faces.yaml").is_file():
        return None
    faces_compose = [
        "docker",
        "compose",
        "--project-name",
        config["name"],
        "--env-file",
        str(source_env),
        "--env-file",
        str(faces_env),
        "-f",
        "compose.yaml",
        "-f",
        "compose.faces.yaml",
    ]
    faces_active = run(*faces_compose, "ps", "--services", "--filter", "status=running").splitlines()
    if FACES_VOLUME not in faces_active:
        return None
    faces_config = json.loads(run(*faces_compose, "config", "--format", "json"))
    base_services = set(config.get("services", {}))
    faces_only = [service for service in faces_active if service not in base_services]
    return {
        "compose": faces_compose,
        "services": faces_only,
        "volume": faces_config["volumes"][FACES_VOLUME]["name"],
        "image": faces_config["services"][FACES_VOLUME]["image"],
        "env_file": faces_env,
    }


def parse_blob_records(records_text):
    records = []
    for line in records_text.splitlines():
        if not line:
            continue
        expected, size = line.split("|")
        if not SHA256_RE.fullmatch(expected):
            raise ValueError("Invalid content hash in database.")
        records.append((expected, int(size)))
    return records


def inspect_media_blobs_archive(archive_path, verify_hashes=False):
    blobs = {}
    with tarfile.open(archive_path, "r") as archive:
        for member in archive.getmembers():
            parts = Path(member.name).parts
            if parts and parts[0] == ".":
                parts = parts[1:]
            if len(parts) >= 2 and parts[0] == "media" and parts[1] in ("previews", "staging"):
                raise ValueError(f"Media blobs archive unexpectedly includes {member.name}.")
            if not member.isfile():
                continue
            if len(parts) == 4 and parts[0] == "media" and parts[1] == "blobs":
                prefix, name = parts[2], parts[3]
                if SHA256_RE.fullmatch(name) and prefix == name[:2]:
                    if verify_hashes:
                        extracted = archive.extractfile(member)
                        if extracted is None:
                            raise RuntimeError(f"Could not read archived blob: {name}")
                        hasher = hashlib.sha256()
                        actual_size = 0
                        with extracted:
                            while block := extracted.read(1024 * 1024):
                                hasher.update(block)
                                actual_size += len(block)
                        if hasher.hexdigest() != name or actual_size != member.size:
                            raise RuntimeError(f"Archived blob failed integrity verification: {name}")
                    blobs[name] = member.size
    return blobs


def verify_blobs_in_archive(referenced_blobs, archive_path, verify_hashes=False):
    archived = inspect_media_blobs_archive(archive_path, verify_hashes=verify_hashes)
    missing = [sha for sha, _ in referenced_blobs if sha not in archived]
    if missing:
        raise RuntimeError(f"Referenced blobs missing from {archive_path.name}: {', '.join(missing[:5])}")
    for sha, expected_size in referenced_blobs:
        if archived[sha] != expected_size:
            raise RuntimeError(f"Archived blob size mismatch for {sha}: expected {expected_size}, got {archived[sha]}")
    return len(referenced_blobs)


def create(path, online=False):
    if online:
        return create_online(path)
    os.umask(0o077)
    path.mkdir(parents=True, exist_ok=False)
    config = json.loads(run("docker", "compose", "config", "--format", "json"))
    active = run("docker", "compose", "ps", "--services", "--filter", "status=running").splitlines()
    if not active:
        raise RuntimeError("Start the deployment before taking its first backup.")
    images = {name: config["services"][name]["image"] for name in ("postgres", "rabbitmq")}
    source_env = Path(os.environ.get("NEPHOS_ENV_FILE", str(ROOT / ".env")))
    faces_env = Path(os.environ.get("NEPHOS_FACES_ENV_FILE", str(ROOT / ".env.faces")))
    faces = detect_faces(config, active, source_env, faces_env)
    manifest = {"format": 1, "images": images, "archives": {}, "sourceProject": config["name"]}
    faces_stopped = False
    base_stopped = False
    try:
        if faces and faces["services"]:
            run(*faces["compose"], "stop", *faces["services"])
            faces_stopped = True
        run("docker", "compose", "stop", *active)
        base_stopped = True
        for name in VOLUMES:
            volume = config["volumes"][name]["name"]
            run("docker", "volume", "inspect", volume)
            export_volume(volume, path / (name + ".tar"))
            manifest["archives"][name] = digest(path / (name + ".tar"))
        copy_private_file(source_env, path / ".env")
        manifest["credentialsChecksum"] = digest(path / ".env")
        if faces:
            run("docker", "volume", "inspect", faces["volume"])
            faces_archive = FACES_VOLUME + ".tar"
            export_volume(faces["volume"], path / faces_archive)
            copy_private_file(faces["env_file"], path / ".env.faces")
            manifest["faces"] = {
                "archive": faces_archive,
                "archiveChecksum": digest(path / faces_archive),
                "credentialsChecksum": digest(path / ".env.faces"),
                "image": faces["image"],
            }
        write_private_json(path / "manifest.json", manifest)
    finally:
        try:
            if base_stopped:
                run("docker", "compose", "start", *active)
        finally:
            if faces_stopped:
                run(*faces["compose"], "start", *faces["services"])
    print("Cold backup created at", path, "(plaintext secrets/media; keep on encrypted private storage).")


def create_online(path):
    os.umask(0o077)
    path.mkdir(parents=True, exist_ok=False)
    config = json.loads(run("docker", "compose", "config", "--format", "json"))
    active = run("docker", "compose", "ps", "--services", "--filter", "status=running").splitlines()
    if not active:
        raise RuntimeError("Start the deployment before taking its first backup.")
    if "postgres" not in active:
        raise RuntimeError("PostgreSQL must be running to take an online backup.")
    source_env = Path(os.environ.get("NEPHOS_ENV_FILE", str(ROOT / ".env")))
    faces_env = Path(os.environ.get("NEPHOS_FACES_ENV_FILE", str(ROOT / ".env.faces")))
    faces = detect_faces(config, active, source_env, faces_env)
    base_compose = ["docker", "compose"]
    images = {"postgres": config["services"]["postgres"]["image"]}
    if faces:
        images["facesPostgres"] = faces["image"]

    manifest = {
        "format": 2,
        "mode": "online",
        "sourceProject": config["name"],
        "hasFaces": bool(faces),
        "images": images,
        "globals": {},
        "databases": {},
    }

    cleanup_stopped = False
    try:
        # Stop only the daily cleanup job so GC cannot unlink a referenced blob mid-backup.
        if "cleanup" in active:
            run("docker", "compose", "stop", "cleanup")
            cleanup_stopped = True

        globals_path = path / "globals.sql"
        dump_globals(base_compose, "postgres", globals_path)
        manifest["globals"]["postgres"] = {"file": "globals.sql", "sha256": digest(globals_path)}

        if faces:
            faces_globals_path = path / "faces-globals.sql"
            dump_globals(faces["compose"], FACES_VOLUME, faces_globals_path)
            manifest["globals"]["faces"] = {"file": "faces-globals.sql", "sha256": digest(faces_globals_path)}

            faces_dump_path = path / "faces.dump"
            dump_database(faces["compose"], FACES_VOLUME, FACES_DATABASE, faces_dump_path)
            manifest["databases"]["faces"] = {"file": "faces.dump", "sha256": digest(faces_dump_path)}

        for database in BASE_DATABASES:
            dump_path = path / f"{database}.dump"
            dump_database(base_compose, "postgres", database, dump_path)
            manifest["databases"][database] = {"file": f"{database}.dump", "sha256": digest(dump_path)}

        referenced_text = run(
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
            LIVE_BLOBS_SQL,
        )
        referenced_blobs = parse_blob_records(referenced_text)

        media_volume = config["volumes"]["media"]["name"]
        run("docker", "volume", "inspect", media_volume)
        media_blobs_path = path / MEDIA_BLOBS_ARCHIVE
        export_media_blobs(media_volume, media_blobs_path)

        verify_blobs_in_archive(referenced_blobs, media_blobs_path, verify_hashes=False)
        manifest["mediaBlobs"] = {"file": MEDIA_BLOBS_ARCHIVE, "sha256": digest(media_blobs_path)}

        copy_private_file(source_env, path / ".env")
        manifest["credentialsChecksum"] = digest(path / ".env")
        if faces:
            copy_private_file(faces["env_file"], path / ".env.faces")
            manifest["facesCredentialsChecksum"] = digest(path / ".env.faces")

        write_private_json(path / "manifest.json", manifest)
    finally:
        if cleanup_stopped:
            run("docker", "compose", "start", "cleanup")
    print("Online backup created at", path, "(plaintext secrets/media; keep on encrypted private storage).")


def wait_for_postgres(container, timeout=60, tcp=False):
    deadline = time.monotonic() + timeout
    command = ["docker", "exec", container, "pg_isready"]
    if tcp:
        command.extend(["-h", "127.0.0.1"])
    command.extend(["-U", "postgres"])
    while True:
        try:
            run(*command)
            return
        except subprocess.CalledProcessError as error:
            if time.monotonic() >= deadline:
                raise RuntimeError("Restored PostgreSQL failed readiness.") from error
            time.sleep(1)


def filter_globals_sql(raw_sql):
    # Skip bootstrap role creation because the fresh cluster already defines the postgres superuser.
    lines = [line for line in raw_sql.splitlines(keepends=True) if not CREATE_POSTGRES_ROLE_RE.fullmatch(line.strip())]
    return "".join(lines)


def apply_globals(container, globals_path):
    filtered = filter_globals_sql(globals_path.read_text(encoding="utf-8"))
    run_stdin(
        ["docker", "exec", "-i", container, "psql", "-U", "postgres", "-d", "postgres", "-v", "ON_ERROR_STOP=1"],
        input_bytes=filtered.encode("utf-8"),
    )


def restore_database_dump(container, dump_path):
    with dump_path.open("rb") as source:
        run_stdin(
            [
                "docker",
                "exec",
                "-i",
                container,
                "pg_restore",
                "-U",
                "postgres",
                "--create",
                "--exit-on-error",
                "-d",
                "postgres",
            ],
            stdin_file=source,
        )


def reconcile_restored_storage(container):
    run_stdin(
        ["docker", "exec", "-i", container, "psql", "-U", "postgres", "-d", "storage", "-v", "ON_ERROR_STOP=1"],
        input_bytes=ONLINE_RESTORE_RECONCILE_SQL.encode("utf-8"),
    )
    # Reconcile cross-DB outbox state: any stored upload published before or between library.dump and storage.dump
    # that is missing from library.assets (or was buffered in the unbacked-up RabbitMQ queue) must be replayed.
    sent_ids = [
        line.strip()
        for line in run(
            "docker",
            "exec",
            container,
            "psql",
            "-U",
            "postgres",
            "-d",
            "storage",
            "-Atc",
            "SELECT o.id FROM outbox o JOIN uploads u ON u.id = o.id "
            "WHERE u.state = 'stored' AND u.released_at IS NULL AND o.sent_at IS NOT NULL",
        ).splitlines()
        if line.strip()
    ]
    if not sent_ids:
        return
    projected_ids = {
        line.strip()
        for line in run(
            "docker",
            "exec",
            container,
            "psql",
            "-U",
            "postgres",
            "-d",
            "library",
            "-Atc",
            "SELECT id FROM assets",
        ).splitlines()
        if line.strip()
    }
    unprojected = [asset_id for asset_id in sent_ids if asset_id not in projected_ids]
    if not unprojected:
        return
    for asset_id in unprojected:
        uuid.UUID(asset_id)
    array_literal = "ARRAY[" + ",".join(f"'{asset_id}'::uuid" for asset_id in unprojected) + "]"
    run_stdin(
        ["docker", "exec", "-i", container, "psql", "-U", "postgres", "-d", "storage", "-v", "ON_ERROR_STOP=1"],
        input_bytes=f"BEGIN;\nUPDATE outbox SET sent_at = NULL WHERE id = ANY({array_literal});\nCOMMIT;\n".encode(),
    )


def populate_online_postgres(container, image, globals_path, dump_paths, volume=None, reconcile_storage=False):
    command = [
        "docker",
        "run",
        "-d",
        "--name",
        container,
        "--network",
        "none",
        "-e",
        "POSTGRES_PASSWORD=" + secrets.token_hex(24),
    ]
    if volume is not None:
        command.extend(["-v", volume + ":/var/lib/postgresql"])
    command.append(image)
    run(*command)
    # Wait on TCP so initdb's temporary Unix-socket server finishes before psql connects.
    wait_for_postgres(container, timeout=60, tcp=True)
    apply_globals(container, globals_path)
    for dump_path in dump_paths:
        restore_database_dump(container, dump_path)
    if reconcile_storage:
        reconcile_restored_storage(container)


def _create_labeled_volumes(project, volume_names, created=None):
    if not re.fullmatch(r"[a-z0-9][a-z0-9_-]{2,48}", project):
        raise ValueError("Invalid restore project name.")
    existing = set(run("docker", "volume", "ls", "--format", "{{.Name}}").splitlines())
    targets = {name: project + "_" + name for name in volume_names}
    if any(name in existing for name in targets.values()):
        raise RuntimeError("Refusing to overwrite an existing restore volume.")
    for name, target in targets.items():
        run(
            "docker",
            "volume",
            "create",
            "--label",
            "com.docker.compose.project=" + project,
            "--label",
            "com.docker.compose.volume=" + name,
            target,
        )
        if created is not None:
            created.append(target)
    return targets


def restore_volumes(path, project, created=None):
    manifest = verify_manifest(path)
    if manifest["format"] == 2:
        return restore_online_volumes(path, project, manifest, created=created)
    volume_names = list(VOLUMES)
    if "faces" in manifest:
        volume_names.append(FACES_VOLUME)
    targets = _create_labeled_volumes(project, volume_names, created=created)
    for name in VOLUMES:
        run(
            "docker",
            "run",
            "--rm",
            "-v",
            targets[name] + ":/target",
            "-v",
            str(path) + ":/backup:ro",
            "alpine:3.23",
            "tar",
            "-xf",
            "/backup/" + name + ".tar",
            "-C",
            "/target",
        )
    if "faces" in manifest:
        run(
            "docker",
            "run",
            "--rm",
            "-v",
            targets[FACES_VOLUME] + ":/target",
            "-v",
            str(path) + ":/backup:ro",
            "alpine:3.23",
            "tar",
            "-xf",
            "/backup/" + manifest["faces"]["archive"],
            "-C",
            "/target",
        )
    return manifest, targets


def restore_online_volumes(path, project, manifest, created=None):
    volume_names = list(VOLUMES)
    if manifest["hasFaces"]:
        volume_names.append(FACES_VOLUME)
    targets = _create_labeled_volumes(project, volume_names, created=created)
    media_blobs_path = path / manifest["mediaBlobs"]["file"]
    with media_blobs_path.open("rb") as archive:
        run_stdin(
            [
                "docker",
                "run",
                "--rm",
                "-i",
                "--network",
                "none",
                "-v",
                targets["media"] + ":/target",
                "alpine:3.23",
                "tar",
                "-xf",
                "-",
                "-C",
                "/target",
            ],
            stdin_file=archive,
        )
    helpers = []
    try:
        pg_helper = f"{project}-restore-postgres-{uuid.uuid4().hex[:8]}"
        helpers.append(pg_helper)
        populate_online_postgres(
            pg_helper,
            manifest["images"]["postgres"],
            path / manifest["globals"]["postgres"]["file"],
            [path / manifest["databases"][db]["file"] for db in BASE_DATABASES],
            volume=targets["postgres"],
            reconcile_storage=True,
        )
        run("docker", "stop", pg_helper)
        if manifest["hasFaces"]:
            faces_helper = f"{project}-restore-faces-{uuid.uuid4().hex[:8]}"
            helpers.append(faces_helper)
            populate_online_postgres(
                faces_helper,
                manifest["images"]["facesPostgres"],
                path / manifest["globals"]["faces"]["file"],
                [path / manifest["databases"][FACES_DATABASE]["file"]],
                volume=targets[FACES_VOLUME],
                reconcile_storage=False,
            )
            run("docker", "stop", faces_helper)
    finally:
        if helpers:
            existing = run("docker", "ps", "-a", "--format", "{{.Names}}").splitlines()
            for helper in helpers:
                if helper in existing:
                    run("docker", "rm", "-f", helper)
    return manifest, targets


def verify_restore(path, expected_queued=0, expected_sets=0, expected_snapshots=0):
    manifest = verify_manifest(path)
    if manifest["format"] == 2:
        return verify_restore_v2(
            path,
            manifest,
            expected_sets=expected_sets,
            expected_snapshots=expected_snapshots,
        )
    return verify_restore_v1(
        path,
        expected_queued=expected_queued,
        expected_sets=expected_sets,
        expected_snapshots=expected_snapshots,
    )


def verify_restore_v1(path, expected_queued=0, expected_sets=0, expected_snapshots=0):
    project = "nephos-restore-check-" + uuid.uuid4().hex[:12]
    container = project + "-postgres"
    broker = project + "-rabbitmq"
    faces_container = project + "-faces-postgres"
    created = []
    try:
        manifest, targets = restore_volumes(path, project, created)
        run(
            "docker",
            "run",
            "-d",
            "--name",
            container,
            "--network",
            "none",
            "-v",
            targets["postgres"] + ":/var/lib/postgresql",
            manifest["images"]["postgres"],
        )
        wait_for_postgres(container, timeout=60, tcp=False)
        for database in BASE_DATABASES:
            run("docker", "exec", container, "psql", "-U", "postgres", "-d", database, "-Atc", "SELECT 1")
        integrity = run(
            "docker",
            "exec",
            container,
            "psql",
            "-U",
            "postgres",
            "-d",
            "library",
            "-Atc",
            LIBRARY_INTEGRITY_SQL,
        )
        sets, snapshots, invalid_resources, invalid_snapshots = map(int, integrity.split("|"))
        if sets < expected_sets or snapshots < expected_snapshots or invalid_resources or invalid_snapshots:
            raise RuntimeError("Restored resource manifests or frozen gallery views failed integrity checks.")
        records = run(
            "docker",
            "exec",
            container,
            "psql",
            "-U",
            "postgres",
            "-d",
            "storage",
            "-Atc",
            "SELECT b.sha256,b.size FROM blobs b WHERE EXISTS(SELECT 1 FROM blob_references r WHERE r.sha256=b.sha256)",
        )
        checked = 0
        for record in records.splitlines():
            expected, size = record.split("|")
            if not SHA256_RE.fullmatch(expected):
                raise ValueError("Invalid content hash in restored database.")
            source = "/source/media/blobs/" + expected[:2] + "/" + expected
            actual = run(
                "docker",
                "run",
                "--rm",
                "--network",
                "none",
                "-v",
                targets["media"] + ":/source:ro",
                "alpine:3.23",
                "sha256sum",
                source,
            ).split()[0]
            actual_size = run(
                "docker",
                "run",
                "--rm",
                "--network",
                "none",
                "-v",
                targets["media"] + ":/source:ro",
                "alpine:3.23",
                "stat",
                "-c",
                "%s",
                source,
            )
            if actual != expected or actual_size != size:
                raise RuntimeError("Restored original does not match its durable database reference.")
            checked += 1
        if "faces" in manifest:
            run(
                "docker",
                "run",
                "-d",
                "--name",
                faces_container,
                "--network",
                "none",
                "-v",
                targets[FACES_VOLUME] + ":/var/lib/postgresql",
                manifest["faces"]["image"],
            )
            wait_for_postgres(faces_container, timeout=60, tcp=False)
            run("docker", "exec", faces_container, "psql", "-U", "postgres", "-d", FACES_DATABASE, "-Atc", "SELECT 1")
        run(
            "docker",
            "run",
            "-d",
            "--name",
            broker,
            "--hostname",
            "nephos-rabbitmq",
            "--network",
            "none",
            "--memory",
            "512m",
            "-e",
            "RABBITMQ_NODENAME=rabbit@nephos-rabbitmq",
            "-v",
            targets["rabbitmq"] + ":/var/lib/rabbitmq",
            manifest["images"]["rabbitmq"],
        )
        deadline = time.monotonic() + 90
        while True:
            try:
                run("docker", "exec", broker, "rabbitmq-diagnostics", "-q", "check_running")
                break
            except subprocess.CalledProcessError as error:
                if time.monotonic() >= deadline:
                    raise RuntimeError("Restored RabbitMQ failed readiness.") from error
                time.sleep(2)
        queues = run("docker", "exec", broker, "rabbitmqctl", "list_queues", "--quiet", "name", "messages")
        rows = [line.split("\t") for line in queues.splitlines() if "\t" in line]
        queued = sum(int(row[1]) for row in rows if row != ["name", "messages"])
        ready_messages = sum(int(row[1]) for row in rows if row[0] == "nephos.assets.ready")
        if ready_messages < expected_queued:
            raise RuntimeError("Pending broker publications did not survive the cold restore.")
        print(
            f"Isolated restore verified: three databases, {checked} originals, {sets} resource sets, "
            f"{snapshots} snapshots and {queued} queued messages."
        )
    finally:
        existing = run("docker", "ps", "-a", "--format", "{{.Names}}").splitlines()
        for helper in (container, broker, faces_container):
            if helper in existing:
                run("docker", "rm", "-f", helper)
        for volume in created:
            run("docker", "volume", "rm", volume)


def verify_restore_v2(path, manifest, expected_sets=0, expected_snapshots=0):
    project = "nephos-restore-check-" + uuid.uuid4().hex[:12]
    container = project + "-postgres"
    faces_container = project + "-faces-postgres" if manifest["hasFaces"] else None
    helpers = [container] + ([faces_container] if faces_container else [])
    try:
        populate_online_postgres(
            container,
            manifest["images"]["postgres"],
            path / manifest["globals"]["postgres"]["file"],
            [path / manifest["databases"][db]["file"] for db in BASE_DATABASES],
            reconcile_storage=True,
        )
        for database in BASE_DATABASES:
            run("docker", "exec", container, "psql", "-U", "postgres", "-d", database, "-Atc", "SELECT 1")
        reconciled = run(
            "docker",
            "exec",
            container,
            "psql",
            "-U",
            "postgres",
            "-d",
            "storage",
            "-Atc",
            "SELECT (SELECT count(*) FROM uploads WHERE state IN ('uploading','verifying')), "
            "(SELECT count(*) FROM upload_parts)",
        )
        active_uploads, remaining_parts = map(int, reconciled.split("|"))
        if active_uploads or remaining_parts:
            raise RuntimeError("Restored storage database still contains unreconciled in-flight uploads.")
        integrity = run(
            "docker",
            "exec",
            container,
            "psql",
            "-U",
            "postgres",
            "-d",
            "library",
            "-Atc",
            LIBRARY_INTEGRITY_SQL,
        )
        sets, snapshots, invalid_resources, invalid_snapshots = map(int, integrity.split("|"))
        if sets < expected_sets or snapshots < expected_snapshots or invalid_resources or invalid_snapshots:
            raise RuntimeError("Restored resource manifests or frozen gallery views failed integrity checks.")
        records = run(
            "docker",
            "exec",
            container,
            "psql",
            "-U",
            "postgres",
            "-d",
            "storage",
            "-Atc",
            LIVE_BLOBS_SQL,
        )
        checked = verify_blobs_in_archive(
            parse_blob_records(records),
            path / manifest["mediaBlobs"]["file"],
            verify_hashes=True,
        )
        faces_summary = ""
        if faces_container:
            populate_online_postgres(
                faces_container,
                manifest["images"]["facesPostgres"],
                path / manifest["globals"]["faces"]["file"],
                [path / manifest["databases"][FACES_DATABASE]["file"]],
                reconcile_storage=False,
            )
            run("docker", "exec", faces_container, "psql", "-U", "postgres", "-d", FACES_DATABASE, "-Atc", "SELECT 1")
            faces_counts = run(
                "docker",
                "exec",
                faces_container,
                "psql",
                "-U",
                "postgres",
                "-d",
                FACES_DATABASE,
                "-Atc",
                "SELECT (SELECT count(*) FROM people), (SELECT count(*) FROM face_tracks), "
                "(SELECT count(*) FROM corrections)",
            )
            people_count, tracks_count, corrections_count = map(int, faces_counts.split("|"))
            faces_summary = f", faces ({people_count} people, {tracks_count} tracks, {corrections_count} corrections)"
        print(
            f"Isolated online restore verified: three databases, {checked} originals, {sets} resource sets, "
            f"{snapshots} snapshots{faces_summary}."
        )
    finally:
        existing = run("docker", "ps", "-a", "--format", "{{.Names}}").splitlines()
        for helper in helpers:
            if helper in existing:
                run("docker", "rm", "-f", helper)


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("create", "verify", "restore"))
    parser.add_argument("path", type=Path, help="Private backup directory (must not exist when creating)")
    parser.add_argument("project_positional", nargs="?", help="New Compose project name for restore")
    parser.add_argument("--online", action="store_true", help="Take a zero-downtime format v2 online backup")
    parser.add_argument("--project", help="New Compose project name for a non-overwriting restore")
    args = parser.parse_args(argv)
    if args.online and args.operation != "create":
        parser.error("--online is only valid with create")
    if args.operation != "restore" and (args.project or args.project_positional):
        parser.error("project name is only valid with restore")
    if args.operation == "restore":
        if args.project and args.project_positional and args.project != args.project_positional:
            parser.error("Specify the restore project either positionally or with --project, not both.")
        args.project = args.project or args.project_positional
        if not args.project:
            parser.error("A restore project name is required (positional <project> or --project).")
    return parser, args


def main(argv=None):
    parser, args = parse_args(argv)
    path = args.path.resolve()
    if args.operation == "create":
        if path.is_relative_to(ROOT) and not path.is_relative_to(ROOT / "artifacts"):
            parser.error("Store backups outside the repository or under ignored artifacts/.")
        create(path, online=args.online)
    elif args.operation == "verify":
        verify_restore(path)
    else:
        manifest, _ = restore_volumes(path, args.project)
        print("Restored into new volumes. Stop conflicting host ports, then start the matching Compose version with")
        has_faces = manifest.get("hasFaces", False) or "faces" in manifest
        if has_faces:
            print(
                f"docker compose --project-name {args.project} --env-file {path / '.env'} "
                f"--env-file {path / '.env.faces'} -f compose.yaml -f compose.faces.yaml up -d"
            )
        else:
            print(f"docker compose --project-name {args.project} --env-file {path / '.env'} up -d")


if __name__ == "__main__":
    main()
