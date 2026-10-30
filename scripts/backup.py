#!/usr/bin/env python3
"""Cold backups and isolated restore verification; never overwrite an existing volume."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
VOLUMES = ("postgres", "media", "rabbitmq")


def run(*args):
    return subprocess.check_output(args, cwd=ROOT, text=True, stderr=subprocess.PIPE).strip()


def digest(path):
    result = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            result.update(block)
    return result.hexdigest()


def verify_manifest(path):
    manifest = json.loads((path / "manifest.json").read_text())
    if manifest["format"] != 1 or set(manifest["archives"]) != set(VOLUMES):
        raise ValueError("Unsupported or incomplete backup manifest.")
    for name in VOLUMES:
        if digest(path / (name + ".tar")) != manifest["archives"][name]:
            raise ValueError("Archive checksum mismatch: " + name)
    if digest(path / ".env") != manifest["credentialsChecksum"]:
        raise ValueError("Credential file checksum mismatch.")
    return manifest


def export_volume(volume, destination):
    # Docker needs root to read database files; the host must own the archive.
    with destination.open("xb") as archive:
        os.fchmod(archive.fileno(), 0o600)
        subprocess.run(
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
            stdout=archive,
            stderr=subprocess.PIPE,
            cwd=ROOT,
            check=True,
        )
        archive.flush()
        os.fsync(archive.fileno())


def create(path):
    os.umask(0o077)
    path.mkdir(parents=True, exist_ok=False)
    config = json.loads(run("docker", "compose", "config", "--format", "json"))
    active = run("docker", "compose", "ps", "--services", "--filter", "status=running").splitlines()
    if not active:
        raise RuntimeError("Start the deployment before taking its first backup.")
    images = {name: config["services"][name]["image"] for name in ("postgres", "rabbitmq")}
    source_env = Path(os.environ.get("NEPHOS_ENV_FILE", str(ROOT / ".env")))
    manifest = {"format": 1, "images": images, "archives": {}, "sourceProject": config["name"]}
    try:
        run("docker", "compose", "stop", *active)
        for name in VOLUMES:
            volume = config["volumes"][name]["name"]
            run("docker", "volume", "inspect", volume)
            export_volume(volume, path / (name + ".tar"))
            manifest["archives"][name] = digest(path / (name + ".tar"))
        shutil.copyfile(source_env, path / ".env")
        os.chmod(path / ".env", 0o600)
        with (path / ".env").open("rb") as credentials:
            os.fsync(credentials.fileno())
        manifest["credentialsChecksum"] = digest(path / ".env")
        with (path / "manifest.json").open("x") as output:
            json.dump(manifest, output, indent=2)
            output.flush()
            os.fsync(output.fileno())
    finally:
        run("docker", "compose", "start", *active)
    print("Cold backup created at", path, "(plaintext secrets/media; keep on encrypted private storage).")


def restore_volumes(path, project, created=None):
    manifest = verify_manifest(path)
    if not re.fullmatch(r"[a-z0-9][a-z0-9_-]{2,48}", project):
        raise ValueError("Invalid restore project name.")
    existing = set(run("docker", "volume", "ls", "--format", "{{.Name}}").splitlines())
    targets = {name: project + "_" + name for name in VOLUMES}
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
        run(
            "docker",
            "run",
            "--rm",
            "-v",
            target + ":/target",
            "-v",
            str(path) + ":/backup:ro",
            "alpine:3.23",
            "tar",
            "-xf",
            "/backup/" + name + ".tar",
            "-C",
            "/target",
        )
    return manifest, targets


def verify_restore(path, expected_queued=0, expected_sets=0, expected_snapshots=0):
    project = "nephos-restore-check-" + uuid.uuid4().hex[:12]
    container = project + "-postgres"
    broker = project + "-rabbitmq"
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
        deadline = time.monotonic() + 60
        while True:
            try:
                run("docker", "exec", container, "pg_isready", "-U", "postgres")
                break
            except subprocess.CalledProcessError:
                if time.monotonic() >= deadline:
                    raise RuntimeError("Restored PostgreSQL failed readiness.")
                time.sleep(1)
        for database in ("library", "storage", "keycloak"):
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
            """
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
            """,
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
            if not re.fullmatch("[0-9a-f]{64}", expected):
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
            except subprocess.CalledProcessError:
                if time.monotonic() >= deadline:
                    raise RuntimeError("Restored RabbitMQ failed readiness.")
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
        for helper in (container, broker):
            if helper in existing:
                run("docker", "rm", "-f", helper)
        for volume in created:
            run("docker", "volume", "rm", volume)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("create", "verify", "restore"))
    parser.add_argument("path", type=Path, help="Private backup directory (must not exist when creating)")
    parser.add_argument("--project", help="New Compose project name for a non-overwriting restore")
    args = parser.parse_args()
    path = args.path.resolve()
    if args.operation == "create":
        if path.is_relative_to(ROOT) and not path.is_relative_to(ROOT / "artifacts"):
            parser.error("Store backups outside the repository or under ignored artifacts/.")
        create(path)
    elif args.operation == "verify":
        verify_restore(path)
    else:
        if not args.project:
            parser.error("--project is required for restore")
        restore_volumes(path, args.project)
        print("Restored into new volumes. Stop conflicting host ports, then start the matching Compose version with")
        print(f"docker compose --project-name {args.project} --env-file {path / '.env'} up -d")


if __name__ == "__main__":
    main()
