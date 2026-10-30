"""Cold archives must be owned by the caller, not the root container."""

import os
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import backup


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
            with patch.object(backup.subprocess, "run", side_effect=subprocess.CalledProcessError(1, ["docker"])):
                with self.assertRaises(subprocess.CalledProcessError):
                    backup.export_volume("fixture-volume", destination)


if __name__ == "__main__":
    unittest.main()
