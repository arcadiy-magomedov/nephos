"""Infrastructure checks do not replace the real native/service qualification."""

import importlib.util
import io
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("native_qr_ci", Path(__file__).with_name("native-qr-ci.py"))
fixture_module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(fixture_module)


class FixtureTests(unittest.TestCase):
    def fixture(self):
        args = type("Args", (), {})()
        return fixture_module.Fixture(args)

    def test_qualification_requires_shipped_dpop_policy_without_silently_enabling_it(self):
        fixture = self.fixture()
        realm = {
            "clients": [
                {"clientId": "other", "attributes": {"unchanged": "true"}},
                {"clientId": "nephos-ios", "attributes": {"pkce.code.challenge.method": "S256"}},
            ]
        }
        with self.assertRaisesRegex(fixture_module.FixtureError, "must require DPoP"):
            fixture.configure_realm(realm)
        self.assertNotIn("nephos.qr.dpop.required", realm["clients"][1]["attributes"])
        realm["clients"][1]["attributes"]["nephos.qr.dpop.required"] = "true"
        configured = fixture.configure_realm(realm)
        self.assertEqual(configured["clients"][1]["attributes"]["nephos.qr.dpop.required"], "true")
        self.assertEqual(configured["clients"][1]["attributes"]["pkce.code.challenge.method"], "S256")
        self.assertEqual(configured["clients"][0], {"clientId": "other", "attributes": {"unchanged": "true"}})

    def test_readiness_retries_expected_startup_http_errors(self):
        fixture = self.fixture()
        attempts = []

        def ready():
            attempts.append(1)
            if len(attempts) == 1:
                raise fixture_module.FixtureError("HTTP 404 during import")
            return True

        with patch.object(fixture_module.time, "sleep"):
            fixture.wait("realm", ready)
        self.assertEqual(len(attempts), 2)

    def test_readiness_does_not_mask_dead_child(self):
        fixture = self.fixture()
        child = unittest.mock.Mock()
        child.poll.return_value = 7
        child.returncode = 7
        fixture.children.append(child)
        with self.assertRaisesRegex(fixture_module.FixtureError, "service exited 7"):
            fixture.wait("realm", lambda: True)

    def test_failed_command_does_not_echo_service_secrets(self):
        fixture = self.fixture()
        completed = subprocess.CompletedProcess(["service"], 1, stdout=b"private bearer token")
        with patch.object(fixture_module.subprocess, "run", return_value=completed):
            with self.assertRaises(fixture_module.FixtureError) as error:
                fixture.command(["service"])
        self.assertNotIn("private bearer token", str(error.exception))

    def test_cleanup_terminates_real_fixture_owned_group_and_removes_data(self):
        fixture = self.fixture()
        with tempfile.TemporaryDirectory(prefix="native-fixture-unit-", dir=fixture_module.ROOT) as workspace:
            fixture.work = Path(workspace) / "private"
            fixture.work.mkdir(mode=0o700)
            (fixture.work / "secret").write_text("private")
            fixture.start(["python3", "-c", "import time; time.sleep(60)"])
            child = fixture.children[0]
            fixture.close()
            self.assertIsNotNone(child.poll())
            self.assertFalse(fixture.work.exists())

    def test_service_diagnostics_only_emit_exception_classes_and_source_locations(self):
        fixture = self.fixture()
        with tempfile.TemporaryDirectory(prefix="native-fixture-unit-", dir=fixture_module.ROOT) as workspace:
            fixture.work = Path(workspace)
            (fixture.work / "process-0.log").write_text(
                "org.hibernate.PropertyValueException: private bearer token\n"
                "at app.nephos.keycloak.EnrollmentStore.save(EnrollmentStore.java:33)\n"
                "body: secret invitation credentials\n"
            )
            with patch.object(fixture_module.sys, "stderr", io.StringIO()) as output:
                fixture.diagnostics()
            text = output.getvalue()
            self.assertIn("PropertyValueException", text)
            self.assertIn("EnrollmentStore.java:33", text)
            self.assertNotIn("private bearer", text)
            self.assertNotIn("secret invitation", text)


if __name__ == "__main__":
    unittest.main()
