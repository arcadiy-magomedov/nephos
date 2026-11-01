"""Deterministic session, browser-boundary and signed OIDC claim regressions."""

from contextlib import ExitStack
import logging
import os
import secrets
import sys
import time
import types
import unittest
import urllib.error
from unittest.mock import Mock, patch
from urllib.parse import parse_qs, urlsplit


class AdminAuthTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.scope = ExitStack()
        cls.scope.enter_context(
            patch.dict(
                os.environ,
                {
                    "ADMIN_PUBLIC_URL": "http://localhost:18082",
                    "ADMIN_IDENTITY_PUBLIC_URL": "http://localhost:18081",
                    "IDENTITY_URL": "http://keycloak:8080",
                    "LIBRARY_ADMIN_URL": "http://library-admin:8080",
                    "ADMIN_SESSION_SECRET": secrets.token_hex(32),
                    "ADMIN_SESSION_STORE_PASSWORD": secrets.token_hex(32),
                    "ADMIN_OIDC_CLIENT_SECRET": secrets.token_hex(32),
                },
            )
        )
        telemetry = types.ModuleType("admin_telemetry")
        telemetry.instrument = lambda app: None
        telemetry.logger = logging.getLogger("admin-auth-tests")
        telemetry.tracer = Mock()
        telemetry.propagator = Mock()
        cls.scope.enter_context(patch.dict(sys.modules, {"admin_telemetry": telemetry}))
        import admin_web

        cls.web = admin_web

    @classmethod
    def tearDownClass(cls):
        cls.scope.close()
        sys.modules.pop("admin_web", None)
        sys.modules.pop("admin_config", None)

    def setUp(self):
        self.scope = ExitStack()
        self.addCleanup(self.scope.close)
        self.records = {}
        self.scope.enter_context(
            patch.object(self.web.store, "lock", return_value=Mock(acquire=Mock(return_value=True)))
        )
        self.scope.enter_context(patch.object(self.web.store, "get", side_effect=self.records.get))
        self.scope.enter_context(
            patch.object(self.web.store, "set", side_effect=lambda name, value, **_: self.records.update({name: value}))
        )
        self.scope.enter_context(
            patch.object(self.web.store, "delete", side_effect=lambda name: self.records.pop(name, None))
        )
        self.web.app.config["TESTING"] = True
        self.client = self.web.app.test_client()
        self.origin = "http://localhost:18082"

    def get(self, path="/", **kwargs):
        return self.client.get(path, base_url=kwargs.pop("base_url", self.origin), **kwargs)

    def seed(self, roles=None, deadline=None):
        with self.client.session_transaction(base_url=self.origin) as session:
            session["token"] = {
                "access_token": "test-token",
                "expires_at": time.time() + 300,
                "userinfo": {
                    "sub": "operator-fixture",
                    "iss": self.web.ISSUER,
                    "realm_access": {"roles": ["admin"] if roles is None else roles},
                },
            }
            session["deadline"] = deadline if deadline is not None else time.time() + 300
            session["nonce"] = "original-nonce"

    def test_login_page_never_challenges_browser_and_rejects_cross_site_writes(self):
        response = self.get()
        self.assertEqual(response.status_code, 200)
        self.assertNotIn("WWW-Authenticate", response.headers)
        self.assertIn(b"Sign in", response.data)
        self.assertEqual(response.headers["Cache-Control"], "no-store")
        self.assertEqual(self.client.post("/", base_url=self.origin).status_code, 403)
        self.assertEqual(self.client.post("/", base_url=self.origin, headers={"Origin": self.origin}).status_code, 403)
        self.assertEqual(self.get(headers={"Host": "attacker.example"}).status_code, 400)
        self.assertEqual(self.get(base_url="http://127.0.0.1:18082").headers["Location"], self.origin)

    def test_private_origins_reject_insecure_remote_and_ambiguous_urls(self):
        from admin_config import origin

        self.assertEqual(origin("http://LOCALHOST:18082/"), self.origin)
        self.assertEqual(origin("https://admin.example.test"), "https://admin.example.test")
        for value in (
            "http://192.168.1.2:18082",
            "http://localhost:0",
            "http://localhost:65536",
            "http://localhost?",
            "http://localhost#",
            "http://localhost/path",
            "http://localhost\n",
        ):
            with self.subTest(value=value), self.assertRaises(ValueError):
                origin(value)

    def test_expired_and_nonoperator_sessions_cannot_reach_dependencies(self):
        with patch.object(self.web, "call") as dependency:
            self.seed(deadline=time.time() - 1)
            self.assertEqual(self.get().status_code, 401)
            self.seed(roles=[])
            self.assertEqual(self.get().status_code, 403)
            self.seed()
            with self.client.session_transaction(base_url=self.origin) as session:
                session["token"] = {**session["token"], "userinfo": {"iss": "https://old.example"}}
            self.assertEqual(self.get().status_code, 401)
            dependency.assert_not_called()

    def test_requested_pins_are_only_loaded_for_operator_and_are_not_cached_in_session(self):
        self.seed()
        pending = {
            "email": "known@example.test",
            "username": "<known>",
            "pin": "12345678",
            "expiresAt": "2026-11-01T15:30:00Z",
        }
        with patch.object(
            self.web, "call", side_effect=[[], {"principals": [], "libraries": []}, {"requests": [pending]}]
        ) as dependency:
            response = self.get()
            self.assertEqual(response.status_code, 200)
            self.assertIn(b"Requested sign-in PINs", response.data)
            self.assertIn(b"12345678", response.data)
            self.assertIn(b"&lt;known&gt;", response.data)
            self.assertEqual(response.headers["Cache-Control"], "no-store")
            self.assertEqual(
                dependency.call_args.args[0], self.web.IDENTITY + "/realms/nephos/nephos-admin/pin-requests"
            )
            self.assertEqual(dependency.call_args.kwargs, {"identity_service": True})
        with self.client.session_transaction(base_url=self.origin) as session:
            self.assertNotIn("pin_requests", session)
        with patch.object(self.web, "call", side_effect=urllib.error.URLError("unavailable")):
            self.assertEqual(self.get().status_code, 503)

    def test_session_failure_is_explicit_and_fail_closed(self):
        self.seed()
        from redis.exceptions import ConnectionError

        with patch.object(self.web.store, "get", side_effect=ConnectionError), patch.object(self.web, "call") as call:
            self.assertEqual(self.get().status_code, 503)
            call.assert_not_called()

    def test_oidc_start_requires_pkce_and_callback_rejects_wrong_state(self):
        metadata = {
            "issuer": self.web.ISSUER,
            "authorization_endpoint": self.web.ISSUER + "/protocol/openid-connect/auth",
            "token_endpoint": self.web.BACKCHANNEL + "/protocol/openid-connect/token",
        }
        with patch.object(self.web.provider, "load_server_metadata", return_value=metadata):
            start = self.get("/login")
            self.assertEqual(start.status_code, 302)
            query = parse_qs(urlsplit(start.headers["Location"]).query)
            self.assertEqual(query["code_challenge_method"], ["S256"])
            self.assertTrue(query["code_challenge"])
            self.assertTrue(query["nonce"])
            with patch.object(self.web.provider, "fetch_access_token") as exchange:
                response = self.get("/oauth/callback?state=incorrect&code=unused")
                self.assertEqual(response.status_code, 401)
                exchange.assert_not_called()

    def test_provider_outage_and_session_write_failure_do_not_redirect_to_login(self):
        from requests.exceptions import ConnectionError
        from redis.exceptions import ConnectionError as StoreError

        with patch.object(self.web.provider, "load_server_metadata", side_effect=ConnectionError):
            self.assertEqual(self.get("/login").status_code, 503)
        metadata = {
            "issuer": self.web.ISSUER,
            "authorization_endpoint": self.web.ISSUER + "/protocol/openid-connect/auth",
        }
        with (
            patch.object(self.web.provider, "load_server_metadata", return_value=metadata),
            patch.object(self.web.store, "set", side_effect=StoreError),
        ):
            response = self.get("/login")
            self.assertEqual(response.status_code, 503)
            self.assertNotIn("Location", response.headers)

    def test_refresh_omits_nonce_but_cannot_change_identity_or_operator_role(self):
        good = {"sub": "operator-fixture", "iss": self.web.ISSUER, "realm_access": {"roles": ["admin"]}}
        for userinfo, status in [
            (good, 200),
            ({**good, "sub": "another-user"}, 401),
            ({**good, "nonce": "another-nonce"}, 401),
            ({**good, "realm_access": {"roles": []}}, 403),
        ]:
            with self.subTest(status=status, userinfo=userinfo):
                self.seed()
                with self.client.session_transaction(base_url=self.origin) as session:
                    session["token"] = {
                        **session["token"],
                        "expires_at": time.time() - 1,
                        "refresh_token": "refresh-fixture",
                    }
                with (
                    patch.object(
                        self.web.provider,
                        "fetch_access_token",
                        return_value={"access_token": "refreshed-fixture", "expires_at": time.time() + 300},
                    ),
                    patch.object(self.web.provider, "parse_id_token", return_value=userinfo) as parse,
                    patch.object(
                        self.web,
                        "call",
                        side_effect=[[], {"principals": [], "libraries": []}, {"requests": []}],
                    ) as dependency,
                ):
                    self.assertEqual(self.get().status_code, status)
                    self.assertIsNone(parse.call_args.kwargs["nonce"])
                    if status != 200:
                        dependency.assert_not_called()

    def test_real_signed_claim_validation_checks_issuer_audience_nonce_expiry_and_signature(self):
        from joserfc import jwt
        from joserfc.jwk import RSAKey
        from joserfc.errors import JoseError

        key = RSAKey.generate_key()
        claims = {
            "iss": self.web.ISSUER,
            "aud": self.web.CLIENT_ID,
            "sub": "operator-fixture",
            "iat": int(time.time()),
            "exp": int(time.time()) + 300,
            "nonce": "expected-nonce",
        }
        metadata = {"issuer": self.web.ISSUER, "id_token_signing_alg_values_supported": ["RS256"]}
        with (
            self.web.app.test_request_context(),
            patch.object(self.web.provider, "load_server_metadata", return_value=metadata),
            patch.object(self.web.provider, "fetch_jwk_set", return_value={"keys": [key.as_dict(private=False)]}),
        ):

            def parse(values, signing_key=key):
                token = {"id_token": jwt.encode({"alg": "RS256"}, values, signing_key), "access_token": "fixture"}
                return self.web.provider.parse_id_token(
                    token, nonce="expected-nonce", claims_options=self.web.CLAIMS, leeway=0
                )

            self.assertEqual(parse(claims)["sub"], "operator-fixture")
            for changed in (
                {"iss": "https://wrong.example/realm"},
                {"aud": "another-client"},
                {"nonce": "wrong"},
                {"exp": int(time.time()) - 1},
                {"at_hash": "incorrect"},
            ):
                with self.subTest(changed=changed), self.assertRaises(JoseError):
                    parse({**claims, **changed})
            with self.assertRaises(JoseError):
                parse(claims, RSAKey.generate_key())
