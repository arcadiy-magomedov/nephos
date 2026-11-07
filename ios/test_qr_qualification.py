import contextlib
import io
import json
import subprocess
import unittest
from pathlib import Path
from unittest.mock import patch

from qr_qualification import failure_summary


class SafeFailureSummaryTests(unittest.TestCase):
    def test_only_safe_stage_error_and_source_line_are_emitted(self):
        fixture = {
            "testNodes": [
                {
                    "children": [
                        {
                            "nodeType": "Failure Message",
                            "name": (
                                "QREnrollmentUITests.swift:72: QR_STAGE=prepare "
                                "QR_ERROR=url:-1202 secret=must-not-appear token=must-not-appear"
                            ),
                        }
                    ]
                }
            ]
        }
        output = io.StringIO()
        completed = subprocess.CompletedProcess([], 0, stdout=json.dumps(fixture))
        with patch("qr_qualification.subprocess.run", return_value=completed), contextlib.redirect_stdout(output):
            failure_summary(Path("private-result.xcresult"))
        self.assertIn("QREnrollmentUITests.swift:72", output.getvalue())
        self.assertIn("QR_STAGE=prepare QR_ERROR=url:-1202", output.getvalue())
        self.assertNotIn("must-not-appear", output.getvalue())
        self.assertNotIn("private-result", output.getvalue())

    def test_unavailable_or_invalid_diagnostics_do_not_dump_output(self):
        for status, stdout in [(1, "secret"), (0, "secret")]:
            output = io.StringIO()
            result = subprocess.CompletedProcess([], status, stdout=stdout)
            with patch("qr_qualification.subprocess.run", return_value=result), contextlib.redirect_stdout(output):
                failure_summary(Path("private-result.xcresult"))
            self.assertNotIn("secret", output.getvalue())


if __name__ == "__main__":
    unittest.main()
