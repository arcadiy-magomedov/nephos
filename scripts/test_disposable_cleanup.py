"""Disposable integration fixtures must not report success when cleanup fails."""

import runpy
import subprocess
import unittest
from pathlib import Path
from unittest.mock import patch


class DisposableCleanupTests(unittest.TestCase):
    def test_failed_container_cleanup_is_reported(self):
        def run(command, **kwargs):
            code = 23 if command[:2] == ["docker", "rm"] else 0
            if code and kwargs.get("check"):
                raise subprocess.CalledProcessError(code, command)
            return subprocess.CompletedProcess(command, code)

        for filename in ("cleanup-tests.py", "faces-fixture-tests.py", "admin-tests.py"):
            with (
                self.subTest(fixture=filename),
                patch("subprocess.run", side_effect=run),
                patch("subprocess.check_output", return_value="127.0.0.1:15432"),
                self.assertRaises((subprocess.CalledProcessError, RuntimeError)),
            ):
                runpy.run_path(str(Path(__file__).with_name(filename)), run_name="__main__")
