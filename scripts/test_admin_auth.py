"""Deterministic session, browser-boundary and signed OIDC claim regressions."""

from contextlib import ExitStack
import logging
import os
import re
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
        self.assertIn("Sign in", response.get_data(as_text=True))
        self.assertEqual(response.headers["Cache-Control"], "no-store")
        self.assertEqual(self.client.post("/", base_url=self.origin).status_code, 403)
        self.assertEqual(self.client.post("/", base_url=self.origin, headers={"Origin": self.origin}).status_code, 403)
        self.assertEqual(self.get(headers={"Host": "attacker.example"}).status_code, 400)
        self.assertEqual(self.get(base_url="http://127.0.0.1:18082").headers["Location"], self.origin)

    def test_navigation_is_rendered_only_for_authenticated_operators(self):
        navigation = 'aria-label="Main navigation"'
        self.assertNotIn(navigation, self.get().get_data(as_text=True))
        self.seed(roles=[])
        denied = self.get("/users/new")
        self.assertEqual(denied.status_code, 403)
        self.assertNotIn(navigation, denied.get_data(as_text=True))
        self.seed()
        authorized = self.get("/users/new")
        self.assertEqual(authorized.status_code, 200)
        self.assertIn(navigation, authorized.get_data(as_text=True))

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

    def test_invitation_metadata_is_operator_only_and_not_cached_in_session(self):
        self.seed()
        subject = "00000000-0000-0000-0000-000000000001"
        invite = "00000000-0000-0000-0000-000000000002"
        pending = {
            "inviteId": invite,
            "status": "active",
            "expiresAt": "2026-11-01T15:30:00Z",
        }
        path = f"/users/{subject}/invitations/{invite}/status"
        with patch.object(self.web, "call", return_value={"invitations": [pending]}) as dependency:
            response = self.get(path)
            self.assertEqual(response.status_code, 200)
            self.assertEqual(response.json["status"], "pending")
            self.assertNotIn("secret", response.json)
            self.assertEqual(response.headers["Cache-Control"], "no-store")
            self.assertEqual(
                dependency.call_args.args[0],
                self.web.IDENTITY + f"/realms/nephos/nephos-admin/users/{subject}/invitations",
            )
            self.assertTrue(dependency.call_args.kwargs["identity_service"])
        with self.client.session_transaction(base_url=self.origin) as session:
            self.assertNotIn("invitations", session)
        with patch.object(self.web, "call", side_effect=urllib.error.URLError("unavailable")):
            self.assertEqual(self.get(path).status_code, 503)
        self.seed(roles=[])
        with patch.object(self.web, "call") as dependency:
            self.assertEqual(self.get(path).status_code, 403)
            dependency.assert_not_called()

    def test_session_failure_is_explicit_and_fail_closed(self):
        self.seed()
        from redis.exceptions import ConnectionError

        with patch.object(self.web.store, "get", side_effect=ConnectionError), patch.object(self.web, "call") as call:
            self.assertEqual(self.get().status_code, 503)
            call.assert_not_called()

    def test_admin_templates_render_real_contract_shapes_and_escape_user_values(self):
        from flask import render_template

        user = {
            "subject": "00000000-0000-0000-0000-000000000001",
            "login": "fixture",
            "displayName": "<script>untrusted</script>",
            "enabled": True,
            "discoverable": True,
            "revision": 1,
            "personalLibraryId": None,
            "provisioningStatus": "completed",
        }
        library = {"id": "00000000-0000-0000-0000-000000000002", "name": "<library>", "members": [], "revision": 1}
        contexts = {
            "users.html": {"data": {"items": [user], "total": 1}, "search": "", "access": ""},
            "user.html": {"user": user, "devices": [], "invitations": [], "libraries": [], "operation": None},
            "user-form.html": {"user": user, "values": {}},
            "libraries.html": {"data": {"items": [library], "total": 1}, "search": ""},
            "library.html": {"library": library},
            "library-form.html": {"library": library, "values": {}, "owners": [], "heading": "Rename library"},
            "overview.html": {
                "counts": {"users": 1, "enabledUsers": 1, "libraries": 1},
                "operations": [],
                "metrics": [],
            },
            "services.html": {"services": []},
            "operation.html": {"operation": {"id": "operation", "status": "pending", "kind": "create"}},
            "confirm.html": {"fields": {}, "heading": "Confirmation", "button": "Revoke"},
            "invitation.html": {"user": user, "invitation": None},
        }
        with self.web.app.test_request_context(base_url=self.origin):
            for template, context in contexts.items():
                with self.subTest(template=template):
                    html = render_template(template, **context)
                    self.assertIn('lang="en"', html)
                    self.assertNotIn("<script>untrusted</script>", html)
                    if template in ("user.html", "users.html", "invitation.html"):
                        self.assertIn("&lt;script&gt;untrusted&lt;/script&gt;", html)

    def test_profile_command_cannot_restore_access_and_keeps_revision(self):
        self.seed()
        subject = "00000000-0000-0000-0000-000000000001"
        operation = "00000000-0000-0000-0000-000000000002"
        user = {
            "subject": subject,
            "login": "known",
            "displayName": "Known",
            "enabled": False,
            "discoverable": False,
            "revision": 7,
        }
        with patch.object(self.web, "library_call", return_value={"user": user}) as backend:
            page = self.get(f"/users/{subject}/edit").get_data(as_text=True)
            csrf = re.search(r'name="csrf" value="([^"]+)"', page)[1]
            command = re.search(r'name="command" value="([^"]+)"', page)[1]
            backend.side_effect = [{"user": user}, {"id": operation}]
            response = self.client.post(
                f"/users/{subject}/edit",
                base_url=self.origin,
                headers={"Origin": self.origin},
                data={
                    "csrf": csrf,
                    "command": command,
                    "revision": "7",
                    "displayName": "Updated",
                    "discoverable": "yes",
                },
            )
            self.assertEqual(response.status_code, 303)
            sent = backend.call_args.args[1]
            self.assertEqual(sent["expectedRevision"], 7)
            self.assertEqual(sent["commandId"], command)
            self.assertNotIn("enabled", sent)

    def test_new_user_requires_valid_login_and_does_not_call_backend_on_bad_input(self):
        self.seed()
        page = self.get("/users/new").get_data(as_text=True)
        csrf = re.search(r'name="csrf" value="([^"]+)"', page)[1]
        command = re.search(r'name="command" value="([^"]+)"', page)[1]
        with patch.object(self.web, "library_call") as backend:
            response = self.client.post(
                "/users/new",
                base_url=self.origin,
                headers={"Origin": self.origin},
                data={"csrf": csrf, "command": command, "login": "invalid login", "displayName": "Known"},
            )
            self.assertEqual(response.status_code, 400)
            backend.assert_not_called()

    def test_create_user_opens_completed_user_or_pending_operation(self):
        self.seed()
        subject = "00000000-0000-0000-0000-000000000001"
        operation = "00000000-0000-0000-0000-000000000002"
        page = self.get("/users/new").get_data(as_text=True)
        csrf = re.search(r'name="csrf" value="([^"]+)"', page)[1]
        command = re.search(r'name="command" value="([^"]+)"', page)[1]
        for result, location in (
            ({"id": operation, "status": "completed", "subject": subject}, "/users/" + subject),
            ({"id": operation, "status": "pending"}, "/operations/" + operation),
        ):
            with (
                self.subTest(status=result["status"]),
                patch.object(self.web, "library_call", return_value={"id": operation}) as backend,
                patch.object(self.web, "wait_operation", return_value=result),
            ):
                response = self.client.post(
                    "/users/new",
                    base_url=self.origin,
                    headers={"Origin": self.origin},
                    data={"csrf": csrf, "command": command, "login": "known", "displayName": "Known"},
                )
                self.assertEqual(response.status_code, 303)
                self.assertEqual(response.headers["Location"], location)
                self.assertEqual(backend.call_args.args[1]["libraryName"], "Personal library")
                self.assertEqual(backend.call_args.args[1]["id"], command)

    def test_qr_issue_timeout_reuses_command_and_does_not_redisplay_secret(self):
        self.seed()
        subject = "00000000-0000-0000-0000-000000000001"
        invite = "00000000-0000-0000-0000-000000000002"
        user = {"subject": subject, "login": "known", "displayName": "Known", "enabled": True}
        pending = {"inviteId": invite, "status": "active", "expiresAt": "2026-11-01T15:30:00Z"}
        commands = []

        def identity(path, data=None, method=None):
            if data:
                commands.append(data["commandId"])
                if len(commands) == 1:
                    raise urllib.error.URLError("response lost")
                return pending
            if path.endswith("/devices"):
                return {"devices": []}
            return {"invitations": [pending]}

        with (
            patch.object(self.web, "library_call", return_value={"user": user, "libraries": [], "memberships": []}),
            patch.object(self.web, "identity_call", side_effect=identity),
        ):
            path = f"/users/{subject}/invitations/new"
            page = self.get(path).get_data(as_text=True)
            csrf = re.search(r'name="csrf" value="([^"]+)"', page)[1]
            command = re.findall(r'name="command" value="([^"]+)"', page)[-1]
            values = {"csrf": csrf, "command": command}
            failed = self.client.post(path, base_url=self.origin, headers={"Origin": self.origin}, data=values)
            self.assertEqual(failed.status_code, 503)
            self.assertIn('value="' + command + '"', failed.get_data(as_text=True))
            self.assertIn("Retry safely", failed.get_data(as_text=True))
            replay = self.client.post(path, base_url=self.origin, headers={"Origin": self.origin}, data=values)
            self.assertEqual(replay.status_code, 200)
            self.assertEqual(commands, [command, command])
            self.assertIn("code was not retained", replay.get_data(as_text=True))
            self.assertIn("Cancel QR code", replay.get_data(as_text=True))
            self.assertNotIn('<img class="qr"', replay.get_data(as_text=True))

    def test_terminal_qr_replay_does_not_offer_an_active_code_without_javascript(self):
        self.seed()
        subject = "00000000-0000-0000-0000-000000000001"
        invite = "00000000-0000-0000-0000-000000000002"
        user = {"subject": subject, "login": "known", "displayName": "Known", "enabled": True}
        expired = {"inviteId": invite, "status": "expired", "expiresAt": "2026-11-01T15:30:00Z"}

        def identity(path, data=None, method=None):
            if data:
                return expired
            if path.endswith("/devices"):
                return {"devices": []}
            return {"invitations": [expired]}

        with (
            patch.object(self.web, "library_call", return_value={"user": user, "libraries": [], "memberships": []}),
            patch.object(self.web, "identity_call", side_effect=identity),
        ):
            path = f"/users/{subject}/invitations/new"
            page = self.get(path).get_data(as_text=True)
            csrf = re.search(r'name="csrf" value="([^"]+)"', page)[1]
            command = re.findall(r'name="command" value="([^"]+)"', page)[-1]
            response = self.client.post(
                path, base_url=self.origin, headers={"Origin": self.origin}, data={"csrf": csrf, "command": command}
            )
            html = response.get_data(as_text=True)
            self.assertEqual(response.status_code, 200)
            self.assertRegex(html, r'<form id="cancel-invitation"[^>]+hidden>')
            self.assertRegex(html, r'id="invitation-finished-actions"\s*><a[^>]+>Close</a>')
            self.assertNotIn("code was not retained", html)
            self.assertNotIn('<img class="qr"', html)

    def test_device_revoke_targets_selected_device_and_retries_unconfirmed_response(self):
        self.seed()
        subject = "00000000-0000-0000-0000-000000000001"
        selected = "00000000-0000-0000-0000-000000000002"
        other = "00000000-0000-0000-0000-000000000003"
        user = {"subject": subject, "login": "known", "displayName": "Known", "enabled": True}
        devices = [
            {"id": selected, "name": "Selected phone", "lastAccess": "2026-11-01T15:30:00Z"},
            {"id": other, "name": "Other phone", "lastAccess": "2026-11-01T15:30:00Z"},
        ]
        attempts = []

        def identity(path, data=None, method=None):
            if method == "DELETE":
                attempts.append(path)
                if len(attempts) == 1:
                    raise urllib.error.URLError("response lost")
                devices[:] = [device for device in devices if device["id"] != selected]
                return None
            if path.endswith("/devices"):
                return {"devices": devices}
            return {"invitations": []}

        with (
            patch.object(self.web, "library_call", return_value={"user": user, "libraries": [], "memberships": []}),
            patch.object(self.web, "identity_call", side_effect=identity),
        ):
            path = f"/users/{subject}/devices/{selected}/revoke"
            page = self.get(path).get_data(as_text=True)
            self.assertIn("Selected phone", page)
            csrf = re.search(r'name="csrf" value="([^"]+)"', page)[1]
            failed = self.client.post(path, base_url=self.origin, headers={"Origin": self.origin}, data={"csrf": csrf})
            self.assertEqual(failed.status_code, 503)
            self.assertIn("Revocation not confirmed", failed.get_data(as_text=True))
            self.assertIn("Do not assume the device is signed out", failed.get_data(as_text=True))
            success = self.client.post(path, base_url=self.origin, headers={"Origin": self.origin}, data={"csrf": csrf})
            self.assertEqual(success.status_code, 303)
            self.assertEqual(success.headers["Location"], "/users/" + subject)
            self.assertEqual(attempts, [f"/users/{subject}/devices/{selected}"] * 2)
            self.assertEqual([device["id"] for device in devices], [other])
            self.assertIn("Device access revoked", self.get(success.headers["Location"]).get_data(as_text=True))
            retry = self.client.post(path, base_url=self.origin, headers={"Origin": self.origin}, data={"csrf": csrf})
            self.assertEqual(retry.status_code, 303)
            self.assertEqual(len(attempts), 2)
            self.assertIn("no longer connected", self.get(retry.headers["Location"]).get_data(as_text=True))

    def test_missing_invitation_is_not_success(self):
        self.seed()
        with patch.object(self.web, "identity_call", return_value={"invitations": []}):
            response = self.get(
                "/users/00000000-0000-0000-0000-000000000001/invitations/00000000-0000-0000-0000-000000000002/status"
            )
            self.assertEqual(response.status_code, 404)

    def test_uuid_route_library_detail_uses_canonical_identifier(self):
        self.seed()
        library_id = "00000000-0000-0000-0000-000000000002"
        with patch.object(
            self.web,
            "library_call",
            return_value={
                "library": {
                    "id": library_id,
                    "name": "Library",
                    "ownerSubject": None,
                    "revision": 0,
                },
                "members": [],
            },
        ) as backend:
            self.assertEqual(self.get("/libraries/" + library_id).status_code, 200)
            self.assertEqual(backend.call_args.args[0], "/libraries/" + library_id)

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
            (good, 303),
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
                    if status != 303:
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
