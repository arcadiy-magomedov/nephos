"""Unit tests for cold and zero-downtime online backups, manifest verification, and restore reconciliation."""

import contextlib
import hashlib
import io
import json
import os
import stat
import subprocess
import tarfile
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

try:
    import backup
except ModuleNotFoundError:
    from scripts import backup


def build_tar_bytes(members):
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w") as archive:
        for name, data in members.items():
            info = tarfile.TarInfo(name=name)
            info.size = len(data)
            archive.addfile(info, io.BytesIO(data))
    return buffer.getvalue()


def create_v2_fixture(directory, *, has_faces=False, blob_payload=b"synthetic-photo-bytes"):
    blob_hash = hashlib.sha256(blob_payload).hexdigest()
    files = {
        "globals.sql": b"CREATE ROLE postgres;\nALTER ROLE postgres WITH SUPERUSER;\nCREATE ROLE library_owner;\n",
        "library.dump": b"PGDMP-library",
        "storage.dump": b"PGDMP-storage",
        "keycloak.dump": b"PGDMP-keycloak",
        "media-blobs.tar": build_tar_bytes({f"media/blobs/{blob_hash[:2]}/{blob_hash}": blob_payload}),
        ".env": b"POSTGRES_PASSWORD=secret\n",
    }
    if has_faces:
        files["faces-globals.sql"] = b"CREATE ROLE postgres;\nCREATE ROLE faces_owner;\n"
        files["faces.dump"] = b"PGDMP-faces"
        files[".env.faces"] = b"FACES_POSTGRES_PASSWORD=faces-secret\n"

    for name, content in files.items():
        target = directory / name
        target.write_bytes(content)
        os.chmod(target, 0o600)

    manifest = {
        "format": 2,
        "mode": "online",
        "sourceProject": "nephos-dev",
        "hasFaces": has_faces,
        "images": {"postgres": "postgres:18-alpine@sha256:base"},
        "globals": {
            "postgres": {"file": "globals.sql", "sha256": backup.digest(directory / "globals.sql")},
        },
        "databases": {
            db: {"file": f"{db}.dump", "sha256": backup.digest(directory / f"{db}.dump")}
            for db in ("library", "storage", "keycloak")
        },
        "mediaBlobs": {"file": "media-blobs.tar", "sha256": backup.digest(directory / "media-blobs.tar")},
        "credentialsChecksum": backup.digest(directory / ".env"),
    }
    if has_faces:
        manifest["images"]["facesPostgres"] = "postgres:18-alpine@sha256:faces"
        manifest["globals"]["faces"] = {
            "file": "faces-globals.sql",
            "sha256": backup.digest(directory / "faces-globals.sql"),
        }
        manifest["databases"]["faces"] = {
            "file": "faces.dump",
            "sha256": backup.digest(directory / "faces.dump"),
        }
        manifest["facesCredentialsChecksum"] = backup.digest(directory / ".env.faces")

    (directory / "manifest.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    return manifest, blob_hash, len(blob_payload)


class ArchiveExportTests(unittest.TestCase):
    def test_tar_is_streamed_into_private_host_owned_file(self):
        payload = b"synthetic tar stream"
        with tempfile.TemporaryDirectory(prefix="nephos-archive-test-") as directory:
            destination = Path(directory) / "database.tar"

            def export(command, *, stdout, **kwargs):
                self.assertIn("fixture-volume:/source:ro", command)
                self.assertIn("--network", command)
                self.assertEqual(["tar", "-cf", "-", "-C", "/source", "."], command[-6:])
                self.assertTrue(kwargs["check"])
                self.assertEqual(0o600, stat.S_IMODE(os.fstat(stdout.fileno()).st_mode))
                stdout.write(payload)

            with patch.object(backup.subprocess, "run", side_effect=export):
                backup.export_volume("fixture-volume", destination)
            self.assertEqual(payload, destination.read_bytes())
            self.assertEqual(os.getuid(), destination.stat().st_uid)
            self.assertEqual(0o600, stat.S_IMODE(destination.stat().st_mode))

    def test_existing_archive_is_never_overwritten(self):
        with tempfile.TemporaryDirectory(prefix="nephos-archive-test-") as directory:
            destination = Path(directory) / "database.tar"
            destination.write_bytes(b"existing")
            with patch.object(backup.subprocess, "run") as process:
                with self.assertRaises(FileExistsError):
                    backup.export_volume("fixture-volume", destination)
                process.assert_not_called()
            self.assertEqual(b"existing", destination.read_bytes())

    def test_failed_tar_export_is_not_success(self):
        with tempfile.TemporaryDirectory(prefix="nephos-archive-test-") as directory:
            destination = Path(directory) / "database.tar"
            with (
                patch.object(backup.subprocess, "run", side_effect=subprocess.CalledProcessError(1, ["docker"])),
                self.assertRaises(subprocess.CalledProcessError),
            ):
                backup.export_volume("fixture-volume", destination)


class ManifestVerificationTests(unittest.TestCase):
    def test_v2_manifest_accepts_valid_backup_without_faces(self):
        with tempfile.TemporaryDirectory(prefix="nephos-v2-manifest-") as directory:
            path = Path(directory)
            expected, _, _ = create_v2_fixture(path, has_faces=False)
            loaded = backup.verify_manifest(path)
            self.assertEqual(expected, loaded)

    def test_v2_manifest_accepts_valid_backup_with_faces(self):
        with tempfile.TemporaryDirectory(prefix="nephos-v2-manifest-") as directory:
            path = Path(directory)
            expected, _, _ = create_v2_fixture(path, has_faces=True)
            loaded = backup.verify_manifest(path)
            self.assertEqual(expected, loaded)

    def test_v2_manifest_rejects_tampered_db_dump(self):
        with tempfile.TemporaryDirectory(prefix="nephos-v2-manifest-") as directory:
            path = Path(directory)
            create_v2_fixture(path, has_faces=True)
            (path / "storage.dump").write_bytes(b"TAMPERED-storage")
            with self.assertRaisesRegex(ValueError, "databases.storage"):
                backup.verify_manifest(path)

    def test_v2_manifest_rejects_tampered_globals(self):
        with tempfile.TemporaryDirectory(prefix="nephos-v2-manifest-") as directory:
            path = Path(directory)
            create_v2_fixture(path, has_faces=True)
            (path / "globals.sql").write_bytes(b"ALTER ROLE postgres WITH NOSUPERUSER;\n")
            with self.assertRaisesRegex(ValueError, "globals.postgres"):
                backup.verify_manifest(path)

    def test_v2_manifest_rejects_tampered_media_blobs(self):
        with tempfile.TemporaryDirectory(prefix="nephos-v2-manifest-") as directory:
            path = Path(directory)
            create_v2_fixture(path, has_faces=False)
            (path / "media-blobs.tar").write_bytes(b"corrupted-tar")
            with self.assertRaisesRegex(ValueError, "mediaBlobs"):
                backup.verify_manifest(path)

    def test_v2_manifest_rejects_missing_faces_credentials_when_has_faces_true(self):
        with tempfile.TemporaryDirectory(prefix="nephos-v2-manifest-") as directory:
            path = Path(directory)
            manifest, _, _ = create_v2_fixture(path, has_faces=True)
            (path / ".env.faces").unlink()
            with self.assertRaisesRegex(ValueError, r"Missing backup file: \.env\.faces"):
                backup.verify_manifest(path)

            (path / ".env.faces").write_bytes(b"FACES_POSTGRES_PASSWORD=faces-secret\n")
            del manifest["facesCredentialsChecksum"]
            (path / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "facesCredentialsChecksum"):
                backup.verify_manifest(path)

    def test_v2_manifest_rejects_unsafe_file_paths(self):
        with tempfile.TemporaryDirectory(prefix="nephos-v2-manifest-") as directory:
            path = Path(directory)
            manifest, _, _ = create_v2_fixture(path, has_faces=False)
            manifest["databases"]["library"]["file"] = "../library.dump"
            (path / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "Unsafe backup file name"):
                backup.verify_manifest(path)

    def test_v1_manifest_preserves_backward_compatibility_and_verifies_optional_faces(self):
        with tempfile.TemporaryDirectory(prefix="nephos-v1-manifest-") as directory:
            path = Path(directory)
            archives = {}
            for name in backup.VOLUMES:
                target = path / f"{name}.tar"
                target.write_bytes(f"v1-{name}".encode())
                archives[name] = backup.digest(target)
            (path / ".env").write_bytes(b"POSTGRES_PASSWORD=base\n")
            manifest = {
                "format": 1,
                "images": {"postgres": "postgres:18-alpine", "rabbitmq": "rabbitmq:4-alpine"},
                "archives": archives,
                "sourceProject": "nephos-dev",
                "credentialsChecksum": backup.digest(path / ".env"),
            }
            (path / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
            self.assertEqual(manifest, backup.verify_manifest(path))

            (path / "faces-postgres.tar").write_bytes(b"v1-faces")
            (path / ".env.faces").write_bytes(b"FACES_POSTGRES_PASSWORD=faces\n")
            manifest["faces"] = {
                "archive": "faces-postgres.tar",
                "archiveChecksum": backup.digest(path / "faces-postgres.tar"),
                "credentialsChecksum": backup.digest(path / ".env.faces"),
                "image": "postgres:18-alpine",
            }
            (path / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
            self.assertEqual(manifest, backup.verify_manifest(path))

            (path / ".env.faces").write_bytes(b"tampered")
            with self.assertRaisesRegex(ValueError, "Faces credential file checksum mismatch"):
                backup.verify_manifest(path)


class OnlineBackupFlowTests(unittest.TestCase):
    def _base_config(self):
        return {
            "name": "nephos-dev",
            "services": {
                "postgres": {"image": "postgres:18-alpine@sha256:base"},
                "rabbitmq": {"image": "rabbitmq:4-management-alpine@sha256:rabbit"},
                "library-api": {"image": "nephos-library"},
                "storage-api": {"image": "nephos-storage"},
                "gateway": {"image": "nginx:1.28-alpine"},
                "keycloak": {"image": "nephos-keycloak:26.8.1"},
                "cleanup": {"image": "nephos-cleanup"},
            },
            "volumes": {
                "postgres": {"name": "nephos-dev_postgres"},
                "media": {"name": "nephos-dev_media"},
                "rabbitmq": {"name": "nephos-dev_rabbitmq"},
            },
        }

    def _faces_config(self):
        cfg = self._base_config()
        cfg["services"]["faces-postgres"] = {"image": "postgres:18-alpine@sha256:faces"}
        cfg["services"]["faces-api"] = {"image": "nephos-faces"}
        cfg["volumes"]["faces-postgres"] = {"name": "nephos-dev_faces-postgres"}
        return cfg

    def test_online_backup_stops_only_cleanup_dumps_all_dbs_and_excludes_previews_and_staging(self):
        blob_bytes = b"immutable-original-bytes"
        blob_hash = hashlib.sha256(blob_bytes).hexdigest()
        media_tar = build_tar_bytes({f"media/blobs/{blob_hash[:2]}/{blob_hash}": blob_bytes})
        user_facing = {"library-api", "storage-api", "gateway", "keycloak", "postgres", "rabbitmq", "faces-api"}

        with tempfile.TemporaryDirectory(prefix="nephos-online-test-") as directory:
            work = Path(directory)
            env_file = work / ".env"
            faces_env_file = work / ".env.faces"
            env_file.write_bytes(b"POSTGRES_PASSWORD=base-secret\n")
            faces_env_file.write_bytes(b"FACES_POSTGRES_PASSWORD=faces-secret\n")
            destination = work / "backup-out"

            run_calls = []
            stream_calls = []

            def fake_run(*args):
                run_calls.append(args)
                if args == ("docker", "compose", "config", "--format", "json"):
                    return json.dumps(self._base_config())
                if args == ("docker", "compose", "ps", "--services", "--filter", "status=running"):
                    return "\n".join(
                        ["postgres", "rabbitmq", "keycloak", "library-api", "storage-api", "gateway", "cleanup"]
                    )
                if "compose.faces.yaml" in args and "ps" in args:
                    return "\n".join(["postgres", "faces-postgres", "faces-api", "cleanup"])
                if "compose.faces.yaml" in args and "config" in args:
                    return json.dumps(self._faces_config())
                if "psql" in args and "storage" in args:
                    return f"{blob_hash}|{len(blob_bytes)}"
                return ""

            def fake_subprocess_run(command, *, stdout=None, **kwargs):
                stream_calls.append(command)
                self.assertTrue(kwargs["check"])
                self.assertEqual(0o600, stat.S_IMODE(os.fstat(stdout.fileno()).st_mode))
                if "pg_dumpall" in command:
                    stdout.write(b"CREATE ROLE postgres;\nCREATE ROLE app_role;\n")
                elif "pg_dump" in command:
                    db = command[-1]
                    stdout.write(f"PGDMP-{db}".encode())
                elif "tar" in command:
                    stdout.write(media_tar)
                else:
                    raise AssertionError(f"Unexpected streamed command: {command}")

            with (
                patch.dict(
                    os.environ,
                    {"NEPHOS_ENV_FILE": str(env_file), "NEPHOS_FACES_ENV_FILE": str(faces_env_file)},
                ),
                patch.object(backup, "run", side_effect=fake_run),
                patch.object(backup.subprocess, "run", side_effect=fake_subprocess_run),
                contextlib.redirect_stdout(io.StringIO()),
            ):
                backup.create(destination, online=True)

            # Verify ONLY cleanup was stopped and restarted; never any user-facing service.
            stop_calls = [call for call in run_calls if "stop" in call]
            start_calls = [call for call in run_calls if "start" in call]
            self.assertEqual([("docker", "compose", "stop", "cleanup")], stop_calls)
            self.assertEqual([("docker", "compose", "start", "cleanup")], start_calls)
            for call in stop_calls:
                self.assertTrue(user_facing.isdisjoint(set(call)))

            # Verify pg_dumpall --globals-only for both postgres and faces-postgres.
            globals_cmds = [cmd for cmd in stream_calls if "pg_dumpall" in cmd]
            self.assertEqual(2, len(globals_cmds))
            self.assertTrue(all("--globals-only" in cmd for cmd in globals_cmds))
            self.assertTrue(any("postgres" in cmd and "faces-postgres" not in cmd for cmd in globals_cmds))
            self.assertTrue(any("faces-postgres" in cmd for cmd in globals_cmds))

            # Verify pg_dump --format=custom for library, storage, keycloak, and faces.
            dump_cmds = [cmd for cmd in stream_calls if "pg_dump" in cmd]
            self.assertTrue(all("--format=custom" in cmd for cmd in dump_cmds))
            dumped_dbs = {cmd[cmd.index("-d") + 1] for cmd in dump_cmds}
            self.assertEqual({"library", "storage", "keycloak", "faces"}, dumped_dbs)

            # Verify tar excludes previews and staging and archives media (blobs).
            tar_cmds = [cmd for cmd in stream_calls if "tar" in cmd]
            self.assertEqual(1, len(tar_cmds))
            tar_cmd = tar_cmds[0]
            self.assertIn("--exclude=media/previews", tar_cmd)
            self.assertIn("--exclude=media/staging", tar_cmd)
            self.assertEqual("media", tar_cmd[-1])

            # Verify all files are mode 0600, host-owned, and manifest passes full verification.
            expected_files = (
                "globals.sql",
                "faces-globals.sql",
                "library.dump",
                "storage.dump",
                "keycloak.dump",
                "faces.dump",
                "media-blobs.tar",
                ".env",
                ".env.faces",
                "manifest.json",
            )
            for filename in expected_files:
                file_path = destination / filename
                self.assertTrue(file_path.is_file(), filename)
                self.assertEqual(0o600, stat.S_IMODE(file_path.stat().st_mode), filename)
                self.assertEqual(os.getuid(), file_path.stat().st_uid, filename)

            manifest = backup.verify_manifest(destination)
            self.assertEqual(2, manifest["format"])
            self.assertEqual("online", manifest["mode"])
            self.assertTrue(manifest["hasFaces"])
            self.assertIn("facesCredentialsChecksum", manifest)
            self.assertEqual("postgres:18-alpine@sha256:faces", manifest["images"]["facesPostgres"])

    def test_online_backup_restarts_cleanup_and_omits_manifest_when_referenced_blob_missing(self):
        missing_hash = hashlib.sha256(b"never-archived").hexdigest()
        empty_media_tar = build_tar_bytes({})

        with tempfile.TemporaryDirectory(prefix="nephos-online-missing-") as directory:
            work = Path(directory)
            env_file = work / ".env"
            env_file.write_bytes(b"POSTGRES_PASSWORD=base-secret\n")
            destination = work / "backup-out"
            run_calls = []

            def fake_run(*args):
                run_calls.append(args)
                if args == ("docker", "compose", "config", "--format", "json"):
                    return json.dumps(self._base_config())
                if args == ("docker", "compose", "ps", "--services", "--filter", "status=running"):
                    return "postgres\nstorage-api\ncleanup"
                if "psql" in args and "storage" in args:
                    return f"{missing_hash}|42"
                return ""

            def fake_subprocess_run(command, *, stdout=None, **kwargs):
                if "tar" in command:
                    stdout.write(empty_media_tar)
                else:
                    stdout.write(b"synthetic")

            with (
                patch.dict(
                    os.environ,
                    {"NEPHOS_ENV_FILE": str(env_file), "NEPHOS_FACES_ENV_FILE": str(work / "absent.env.faces")},
                ),
                patch.object(backup, "run", side_effect=fake_run),
                patch.object(backup.subprocess, "run", side_effect=fake_subprocess_run),
                self.assertRaisesRegex(RuntimeError, "Referenced blobs missing"),
            ):
                backup.create(destination, online=True)

            self.assertIn(("docker", "compose", "stop", "cleanup"), run_calls)
            self.assertIn(("docker", "compose", "start", "cleanup"), run_calls)
            self.assertFalse((destination / "manifest.json").exists())

    def test_online_backup_without_faces_and_without_cleanup_stops_nothing(self):
        blob_bytes = b"single-photo-bytes"
        blob_hash = hashlib.sha256(blob_bytes).hexdigest()
        media_tar = build_tar_bytes({f"media/blobs/{blob_hash[:2]}/{blob_hash}": blob_bytes})

        with tempfile.TemporaryDirectory(prefix="nephos-online-nofaces-") as directory:
            work = Path(directory)
            env_file = work / ".env"
            env_file.write_bytes(b"POSTGRES_PASSWORD=base-secret\n")
            destination = work / "backup-out"
            run_calls = []

            def fake_run(*args):
                run_calls.append(args)
                if args == ("docker", "compose", "config", "--format", "json"):
                    return json.dumps(self._base_config())
                if args == ("docker", "compose", "ps", "--services", "--filter", "status=running"):
                    return "postgres\nrabbitmq\nlibrary-api\nstorage-api\ngateway"
                if "psql" in args and "storage" in args:
                    return f"{blob_hash}|{len(blob_bytes)}"
                return ""

            def fake_subprocess_run(command, *, stdout=None, **kwargs):
                if "tar" in command:
                    stdout.write(media_tar)
                else:
                    stdout.write(b"synthetic")

            with (
                patch.dict(
                    os.environ,
                    {"NEPHOS_ENV_FILE": str(env_file), "NEPHOS_FACES_ENV_FILE": str(work / "absent.env.faces")},
                ),
                patch.object(backup, "run", side_effect=fake_run),
                patch.object(backup.subprocess, "run", side_effect=fake_subprocess_run),
                contextlib.redirect_stdout(io.StringIO()),
            ):
                backup.create(destination, online=True)

            self.assertFalse(any("stop" in call or "start" in call for call in run_calls))
            manifest = backup.verify_manifest(destination)
            self.assertEqual(2, manifest["format"])
            self.assertFalse(manifest["hasFaces"])
            self.assertEqual({"library", "storage", "keycloak"}, set(manifest["databases"]))
            self.assertEqual({"postgres"}, set(manifest["globals"]))
            self.assertNotIn("facesCredentialsChecksum", manifest)

    def test_media_blobs_archive_rejects_previews_or_staging_entries(self):
        with tempfile.TemporaryDirectory(prefix="nephos-tar-exclusion-") as directory:
            archive_path = Path(directory) / "media-blobs.tar"
            archive_path.write_bytes(build_tar_bytes({"media/previews/abc.jpg": b"preview"}))
            with self.assertRaisesRegex(ValueError, "previews"):
                backup.inspect_media_blobs_archive(archive_path)

            archive_path.write_bytes(build_tar_bytes({"media/staging/upload1/0": b"chunk"}))
            with self.assertRaisesRegex(ValueError, "staging"):
                backup.inspect_media_blobs_archive(archive_path)

    def test_cold_backup_includes_optional_faces_while_keeping_v1_format_intact(self):
        with tempfile.TemporaryDirectory(prefix="nephos-cold-faces-") as directory:
            work = Path(directory)
            env_file = work / ".env"
            faces_env_file = work / ".env.faces"
            env_file.write_bytes(b"POSTGRES_PASSWORD=base-secret\n")
            faces_env_file.write_bytes(b"FACES_POSTGRES_PASSWORD=faces-secret\n")
            destination = work / "cold-out"
            run_calls = []

            def fake_run(*args):
                run_calls.append(args)
                if args == ("docker", "compose", "config", "--format", "json"):
                    return json.dumps(self._base_config())
                if args == ("docker", "compose", "ps", "--services", "--filter", "status=running"):
                    return "postgres\nrabbitmq\nlibrary-api"
                if "compose.faces.yaml" in args and "ps" in args:
                    return "postgres\nfaces-postgres\nfaces-api"
                if "compose.faces.yaml" in args and "config" in args:
                    return json.dumps(self._faces_config())
                return ""

            def fake_subprocess_run(command, *, stdout=None, **kwargs):
                stdout.write(b"tar-stream")

            with (
                patch.dict(
                    os.environ,
                    {"NEPHOS_ENV_FILE": str(env_file), "NEPHOS_FACES_ENV_FILE": str(faces_env_file)},
                ),
                patch.object(backup, "run", side_effect=fake_run),
                patch.object(backup.subprocess, "run", side_effect=fake_subprocess_run),
                contextlib.redirect_stdout(io.StringIO()),
            ):
                backup.create(destination)

            manifest = backup.verify_manifest(destination)
            self.assertEqual(1, manifest["format"])
            self.assertEqual(set(backup.VOLUMES), set(manifest["archives"]))
            self.assertEqual("faces-postgres.tar", manifest["faces"]["archive"])
            self.assertEqual("postgres:18-alpine@sha256:faces", manifest["faces"]["image"])
            self.assertTrue((destination / ".env.faces").is_file())
            self.assertEqual(0o600, stat.S_IMODE((destination / ".env.faces").stat().st_mode))
            self.assertEqual(0o600, stat.S_IMODE((destination / "faces-postgres.tar").stat().st_mode))


class OnlineRestoreAndReconciliationTests(unittest.TestCase):
    def test_filter_globals_sql_skips_bootstrap_postgres_role_only(self):
        raw = (
            "\\restrict token123\n"
            "CREATE ROLE library_owner;\n"
            "CREATE ROLE postgres;\n"
            "ALTER ROLE postgres WITH SUPERUSER PASSWORD 'SCRAM-SHA-256$abc';\n"
            "\\unrestrict token123\n"
        )
        filtered = backup.filter_globals_sql(raw)
        self.assertNotIn("CREATE ROLE postgres;", filtered)
        self.assertIn("CREATE ROLE library_owner;", filtered)
        self.assertIn("ALTER ROLE postgres WITH SUPERUSER", filtered)
        self.assertIn("\\restrict token123", filtered)
        self.assertIn("\\unrestrict token123", filtered)

    def test_verify_restore_v2_restores_globals_dbs_reconciles_uploads_and_checks_blobs_and_faces(self):
        with tempfile.TemporaryDirectory(prefix="nephos-v2-restore-") as directory:
            path = Path(directory)
            _, blob_hash, blob_size = create_v2_fixture(path, has_faces=True)

            events = []
            created_containers = []

            def fake_run(*args):
                if args[:3] == ("docker", "run", "-d"):
                    name = args[args.index("--name") + 1]
                    created_containers.append(name)
                    events.append(("start", name))
                    return "cid"
                if "pg_isready" in args:
                    self.assertIn("-h", args)
                    self.assertIn("127.0.0.1", args)
                    return ""
                if args[:3] == ("docker", "ps", "-a"):
                    return "\n".join(created_containers)
                if args[:3] == ("docker", "rm", "-f"):
                    events.append(("rm", args[3]))
                    return ""
                if "psql" in args:
                    db = args[args.index("-d") + 1]
                    sql = args[-1]
                    if sql == "SELECT 1":
                        return "1"
                    if db == "storage" and "upload_parts" in sql:
                        return "0|0"
                    if db == "library":
                        return "2|1|0|0"
                    if db == "storage" and "blob_references" in sql:
                        return f"{blob_hash}|{blob_size}"
                    if db == "faces":
                        return "3|5|1"
                return ""

            def fake_run_stdin(command, *, input_bytes=None, stdin_file=None):
                container = command[3]
                if "psql" in command and command[command.index("-d") + 1] == "postgres":
                    sql_text = input_bytes.decode("utf-8")
                    self.assertNotIn("CREATE ROLE postgres;", sql_text)
                    events.append(("globals", container))
                elif "pg_restore" in command:
                    self.assertIn("--create", command)
                    self.assertIn("--exit-on-error", command)
                    payload = stdin_file.read()
                    events.append(("pg_restore", container, payload.decode("utf-8")))
                elif "psql" in command and command[command.index("-d") + 1] == "storage":
                    sql_text = input_bytes.decode("utf-8")
                    self.assertIn("DELETE FROM upload_parts;", sql_text)
                    self.assertIn("state = 'failed'", sql_text)
                    self.assertIn("Interrupted by online backup restore; retry upload.", sql_text)
                    self.assertIn("staging_cleaned = true", sql_text)
                    self.assertIn("WHERE state IN ('uploading', 'verifying')", sql_text)
                    events.append(("reconcile", container))
                else:
                    raise AssertionError(f"Unexpected stdin command: {command}")

            with (
                patch.object(backup, "run", side_effect=fake_run),
                patch.object(backup, "run_stdin", side_effect=fake_run_stdin),
                contextlib.redirect_stdout(io.StringIO()),
            ):
                backup.verify_restore(path, expected_sets=2, expected_snapshots=1)

            base_container, faces_container = created_containers
            # Base postgres ordering: start -> globals -> pg_restore(library, storage, keycloak) -> reconcile.
            base_events = [ev for ev in events if ev[1] == base_container]
            self.assertEqual(
                [
                    ("start", base_container),
                    ("globals", base_container),
                    ("pg_restore", base_container, "PGDMP-library"),
                    ("pg_restore", base_container, "PGDMP-storage"),
                    ("pg_restore", base_container, "PGDMP-keycloak"),
                    ("reconcile", base_container),
                    ("rm", base_container),
                ],
                base_events,
            )
            # Ordering invariant on faces postgres: start -> globals -> pg_restore(faces) -> rm
            faces_events = [ev for ev in events if ev[1] == faces_container]
            self.assertEqual(
                [
                    ("start", faces_container),
                    ("globals", faces_container),
                    ("pg_restore", faces_container, "PGDMP-faces"),
                    ("rm", faces_container),
                ],
                faces_events,
            )

    def test_reconcile_restored_storage_resets_unprojected_sent_outbox_rows(self):
        projected_id = "11111111-1111-1111-1111-111111111111"
        orphan_id = "22222222-2222-2222-2222-222222222222"
        stdin_calls = []

        def fake_run(*args):
            db = args[args.index("-d") + 1]
            if db == "storage":
                return f"{projected_id}\n{orphan_id}"
            if db == "library":
                return projected_id
            raise AssertionError(f"Unexpected psql query: {args}")

        def fake_run_stdin(command, *, input_bytes=None, stdin_file=None):
            stdin_calls.append((command, input_bytes.decode("utf-8")))

        with (
            patch.object(backup, "run", side_effect=fake_run),
            patch.object(backup, "run_stdin", side_effect=fake_run_stdin),
        ):
            backup.reconcile_restored_storage("restore-pg")

        self.assertEqual(2, len(stdin_calls))
        self.assertIn("DELETE FROM upload_parts;", stdin_calls[0][1])
        self.assertIn("verify_lease_id", stdin_calls[0][1])
        self.assertIn("UPDATE outbox SET sent_at = NULL", stdin_calls[1][1])
        self.assertIn(orphan_id, stdin_calls[1][1])
        self.assertNotIn(projected_id, stdin_calls[1][1])

    def test_verify_restore_v2_rejects_corrupted_blob_and_cleans_up_container(self):
        with tempfile.TemporaryDirectory(prefix="nephos-v2-corrupt-blob-") as directory:
            path = Path(directory)
            real_hash = hashlib.sha256(b"expected-content").hexdigest()
            manifest, _, _ = create_v2_fixture(path, has_faces=False)
            # Replace archive with a blob whose bytes do NOT match its content-addressed filename,
            # while keeping manifest checksum valid to verify deep archive integrity checking.
            bad_tar = build_tar_bytes({f"media/blobs/{real_hash[:2]}/{real_hash}": b"wrong-content-xx"})
            (path / "media-blobs.tar").write_bytes(bad_tar)
            manifest["mediaBlobs"]["sha256"] = backup.digest(path / "media-blobs.tar")
            (path / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")

            removed = []
            started = []

            def fake_run(*args):
                if args[:3] == ("docker", "run", "-d"):
                    started.append(args[args.index("--name") + 1])
                    return "cid"
                if args[:3] == ("docker", "ps", "-a"):
                    return "\n".join(started)
                if args[:3] == ("docker", "rm", "-f"):
                    removed.append(args[3])
                    return ""
                if "psql" in args:
                    db = args[args.index("-d") + 1]
                    sql = args[-1]
                    if sql == "SELECT 1":
                        return "1"
                    if db == "storage" and "upload_parts" in sql:
                        return "0|0"
                    if db == "library":
                        return "0|0|0|0"
                    if db == "storage" and "blob_references" in sql:
                        return f"{real_hash}|16"
                return ""

            with (
                patch.object(backup, "run", side_effect=fake_run),
                patch.object(backup, "run_stdin"),
                self.assertRaisesRegex(RuntimeError, "failed integrity verification"),
            ):
                backup.verify_restore(path)

            self.assertEqual(started, removed)

    def test_cli_flags_support_online_and_positional_or_option_restore_project(self):
        _, args = backup.parse_args(["create", "--online", "/private/backup/nephos-backup"])
        self.assertEqual("create", args.operation)
        self.assertTrue(args.online)
        self.assertEqual(Path("/private/backup/nephos-backup"), args.path)

        _, args = backup.parse_args(["verify", "/private/backup/nephos-backup"])
        self.assertEqual("verify", args.operation)
        self.assertFalse(args.online)

        _, args = backup.parse_args(["restore", "/private/backup/nephos-backup", "nephos-restored"])
        self.assertEqual("restore", args.operation)
        self.assertEqual("nephos-restored", args.project)

        _, args = backup.parse_args(["restore", "/private/backup/nephos-backup", "--project", "nephos-restored"])
        self.assertEqual("restore", args.operation)
        self.assertEqual("nephos-restored", args.project)

        with contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit):
                backup.parse_args(["verify", "--online", "/private/backup/nephos-backup"])
            with self.assertRaises(SystemExit):
                backup.parse_args(["restore", "/private/backup/nephos-backup"])


if __name__ == "__main__":
    unittest.main()
