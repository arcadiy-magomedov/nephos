import copy
import importlib.util
from pathlib import Path
import unittest

SPEC = importlib.util.spec_from_file_location("admin_bootstrap", Path(__file__).with_name("admin-bootstrap.py"))
bootstrap = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(bootstrap)


class MobilePolicyUpgradeTests(unittest.TestCase):
    def test_existing_realm_upgrade_is_idempotent_and_preserves_unrelated_configuration(self):
        base = "/admin/realms/nephos"
        state = {
            base: {"displayName": "Existing realm", "offlineSessionIdleTimeout": 0, "revokeRefreshToken": True},
            base + "/client-policies/profiles": {"profiles": [{"name": "other", "executors": []}]},
            base + "/client-policies/policies": {"policies": [{"name": "other", "enabled": False}]},
            base + "/clients/mobile": {
                "id": "mobile",
                "clientId": "nephos-ios",
                "attributes": {
                    "pkce.code.challenge.method": "S256",
                    "unrelated": "preserved",
                    "client.offline.session.idle.timeout": "86400",
                    "client.offline.session.max.lifespan": "86400",
                },
            },
        }

        def call(path, data=None, token=None, method=None):
            self.assertEqual(token, "admin")
            self.assertIn(path, state)
            if method == "PUT":
                state[path].update(copy.deepcopy(data))
            else:
                self.assertIsNone(data)
                return copy.deepcopy(state[path])

        bootstrap.configure_mobile_policy(call, "admin", "mobile")
        first = copy.deepcopy(state)
        bootstrap.configure_mobile_policy(call, "admin", "mobile")
        self.assertEqual(state, first)
        self.assertEqual(state[base]["displayName"], "Existing realm")
        self.assertEqual(state[base]["offlineSessionIdleTimeout"], 180 * 24 * 60 * 60)
        self.assertFalse(state[base]["revokeRefreshToken"])
        self.assertFalse(state[base]["offlineSessionMaxLifespanEnabled"])
        for collection in ("profiles", "policies"):
            items = state[base + "/client-policies/" + collection][collection]
            self.assertEqual([item["name"] for item in items], ["other", "nephos-persistent-login"])
        attributes = state[base + "/clients/mobile"]["attributes"]
        self.assertEqual(attributes["unrelated"], "preserved")
        self.assertEqual(attributes["pkce.code.challenge.method"], "S256")
        self.assertEqual(attributes["nephos.qr.dpop.required"], "true")
        self.assertNotIn("client.offline.session.idle.timeout", attributes)
        self.assertNotIn("client.offline.session.max.lifespan", attributes)


if __name__ == "__main__":
    unittest.main()
