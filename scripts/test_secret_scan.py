"""Verify publication scans reject simulated keys without printing their values."""

import contextlib
import io
from pathlib import Path
import secrets
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import secret_scan


@unittest.skipUnless(shutil.which("gitleaks"), "gitleaks is required")
class SecretScanTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="nephos-scanner-test-")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        subprocess.run(["git", "init", "--quiet", str(self.root)], check=True)
        shutil.copyfile(secret_scan.ROOT / ".gitleaks.toml", self.root / ".gitleaks.toml")
        self.patch = patch.object(secret_scan, "ROOT", self.root)
        self.patch.start()
        self.addCleanup(self.patch.stop)
        # A generated, unregistered test token; never a real credential.
        self.simulated_key = "ghp_" + secrets.token_hex(18)

    def run_scan(self, **kwargs):
        with contextlib.redirect_stdout(io.StringIO()):
            secret_scan.scan(**kwargs)

    def test_ignored_environment_is_not_copied_but_force_staged_one_is_rejected(self):
        (self.root / ".gitignore").write_text(".env\n")
        (self.root / ".env").write_text("API_TOKEN=" + self.simulated_key)
        self.run_scan()
        subprocess.run(["git", "add", "-f", ".env"], cwd=self.root, check=True)
        with self.assertRaisesRegex(SystemExit, "environment credentials"):
            self.run_scan(staged=True)

    def test_untracked_source_secret_is_rejected(self):
        (self.root / "source.py").write_text('token = "' + self.simulated_key + '"\n')
        with self.assertRaises(SystemExit) as failure:
            self.run_scan()
        self.assertEqual(1, failure.exception.code)

    def test_index_bytes_are_scanned_not_later_working_tree_edits(self):
        source = self.root / "source.py"
        source.write_text('token = "' + self.simulated_key + '"\n')
        subprocess.run(["git", "add", "source.py"], cwd=self.root, check=True)
        source.write_text("token = None\n")
        with self.assertRaises(SystemExit) as failure:
            self.run_scan(staged=True)
        self.assertEqual(1, failure.exception.code)
        self.run_scan()


if __name__ == "__main__":
    unittest.main()
