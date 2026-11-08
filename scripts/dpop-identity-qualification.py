#!/usr/bin/env python3
"""Qualify DPoP refresh binding on disposable loopback services; no Simulator."""

import argparse
import base64
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import signal
import ssl
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec

from dpop_proof import b64, claims, proof, thumbprint

spec = importlib.util.spec_from_file_location("native_fixture", Path(__file__).with_name("native-qr-ci.py"))
native = importlib.util.module_from_spec(spec)
spec.loader.exec_module(native)
bootstrap_spec = importlib.util.spec_from_file_location(
    "admin_bootstrap", Path(__file__).with_name("admin-bootstrap.py")
)
bootstrap = importlib.util.module_from_spec(bootstrap_spec)
bootstrap_spec.loader.exec_module(bootstrap)


class Fixture(native.Fixture):
    def preflight(self):
        for name in ("dotnet", "java", "initdb", "postgres", "psql", "openssl", "caddy"):
            if not shutil.which(name, path=self.env.get("PATH")):
                raise native.FixtureError(f"Missing {name}.")
        version = self.command([self.args.keycloak_dist.resolve() / "bin/kc.sh", "--version"]).decode()
        if f"Keycloak {native.KEYCLOAK_VERSION}" not in version:
            raise native.FixtureError("Pinned Keycloak 26.8.1 is required.")

    def request(self, url, body=None, *, method=None, headers=None, expected=200, form=False):
        headers = dict(headers or {})
        if body is not None:
            headers["Content-Type"] = "application/x-www-form-urlencoded" if form else "application/json"
            body = (urllib.parse.urlencode(body) if form else json.dumps(body)).encode()
        context = ssl.create_default_context(cafile=str(self.work / "ca.pem")) if url.startswith("https:") else None
        query = urllib.request.Request(url, data=body, headers=headers, method=method)
        try:
            response = urllib.request.urlopen(query, context=context, timeout=20)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            assert response.status == expected, f"{self.stage}: HTTP {response.status}, expected {expected}"
            data = response.read()
            return json.loads(data) if data else None

    def restart(self, before_start=None):
        self.kc_process.terminate()
        self.kc_process.wait(timeout=45)
        self.children.remove(self.kc_process)
        if before_start:
            before_start()
        self.kc_process = self.start(self.kc_command, env=self.kc_env)
        self.wait(
            "restarted Keycloak",
            lambda: self.request(self.identity + "/realms/nephos/.well-known/openid-configuration"),
            timeout=180,
        )

    def identity_sql(self, statement):
        return (
            self.command(
                [
                    "psql",
                    "-X",
                    "-v",
                    "ON_ERROR_STOP=1",
                    "-h",
                    "127.0.0.1",
                    "-p",
                    self.pg_port,
                    "-U",
                    "fixture",
                    "-d",
                    "keycloak",
                    "-tAc",
                    statement,
                ],
                env={**self.env, "PGPASSWORD": self.password},
            )
            .decode()
            .strip()
        )

    def qualify(self):
        private = self.identity + "/realms/nephos/nephos-admin"
        token_url = self.origin + "/realms/nephos/protocol/openid-connect/token"
        revoke_url = self.origin + "/realms/nephos/protocol/openid-connect/revoke"
        headers = {"X-Nephos-Identity-Service-Key": self.service_key}
        subject = str(uuid.uuid4())
        self.stage = "provisioning"
        identity = self.request(
            private + "/users/" + subject + "/provision",
            {
                "commandId": str(uuid.uuid4()),
                "requestHash": hashlib.sha256(subject.encode()).hexdigest(),
                "login": "dpop-" + uuid.uuid4().hex,
                "displayName": "DPoP qualification",
            },
            method="PUT",
            headers=headers,
            expected=201,
        )
        identity = self.request(
            private + "/users/" + subject + "/access",
            {
                "commandId": str(uuid.uuid4()),
                "expectedRevision": identity["revision"],
                "enabled": True,
            },
            method="PUT",
            headers=headers,
        )
        config = self.request(self.origin + "/realms/nephos/nephos-admin/enrollment/config")
        assert config["persistentLogin"]["refreshBinding"] == "dpop"

        def device():
            code = self.request(
                private + "/users/" + subject + "/invitations",
                {"commandId": str(uuid.uuid4())},
                method="POST",
                headers=headers,
                expected=201,
            )
            key = ec.generate_private_key(ec.SECP256R1())
            point = key.public_key().public_bytes(
                serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint
            )
            return {
                "key": key,
                "public": b64(point),
                "request": str(uuid.uuid4()),
                "nonce": str(uuid.uuid4()),
                "code": code,
            }

        def exchange(item, *, dpop=True, expected=200):
            challenge = self.request(
                self.origin + "/realms/nephos/nephos-admin/enrollment/challenge",
                {
                    "inviteId": item["code"]["inviteId"],
                    "requestId": item["request"],
                    "clientId": "nephos-ios",
                    "publicKey": item["public"],
                },
                method="POST",
            )
            text = base64.urlsafe_b64decode(challenge["challenge"] + "==")
            form = {
                "grant_type": config["grantType"],
                "client_id": "nephos-ios",
                "invite_id": item["code"]["inviteId"],
                "invite_secret": item["code"]["qr"]["secret"],
                "request_id": item["request"],
                "public_key": item["public"],
                "challenge_id": challenge["challengeId"],
                "signature": b64(item["key"].sign(text, ec.ECDSA(hashes.SHA256()))),
                "device_name": "DPoP qualification",
                "nonce": item["nonce"],
                "scope": "openid offline_access",
            }
            jwt = proof(item["key"], token_url) if dpop is True else dpop
            return self.request(token_url, form, form=True, headers={"DPoP": jwt} if jwt else {}, expected=expected)

        def refresh(item, tokens, *, dpop=True, expected=200):
            jwt = proof(item["key"], token_url) if dpop is True else dpop
            return self.request(
                token_url,
                {
                    "grant_type": "refresh_token",
                    "client_id": "nephos-ios",
                    "refresh_token": tokens["refresh_token"],
                },
                form=True,
                headers={"DPoP": jwt} if jwt else {},
                expected=expected,
            )

        def bound(tokens, item):
            assert tokens["token_type"].lower() == "bearer"
            assert "cnf" not in claims(tokens["access_token"])
            refresh_claims = claims(tokens["refresh_token"])
            assert refresh_claims["typ"] == "Offline"
            assert refresh_claims["cnf"]["jkt"] == thumbprint(item["key"])
            assert refresh_claims.get("iss") == config["issuer"], "Refresh issuer contract mismatch"
            assert refresh_claims.get("sub") == subject, "Refresh subject contract mismatch"
            assert refresh_claims.get("azp") == "nephos-ios", "Refresh authorized-party contract mismatch"
            audience = refresh_claims.get("aud")
            assert audience == config["issuer"] or audience == [config["issuer"]], "Refresh audience contract mismatch"
            assert isinstance(refresh_claims.get("iat"), int), "Refresh issued-at must be NumericDate"
            assert refresh_claims["exp"] > int(time.time()), "Refresh token already expired"
            header = json.loads(base64.urlsafe_b64decode(tokens["refresh_token"].split(".")[0] + "=="))
            assert header["alg"] == "HS512", "Pinned refresh signature category changed"

        self.stage = "initial proof rejection"
        first = device()
        wrong_key = ec.generate_private_key(ec.SECP256R1())
        assert exchange(first, dpop=False, expected=400)["error_description"] == "dpop_proof_required"
        assert (
            exchange(first, dpop=proof(wrong_key, token_url), expected=400)["error_description"] == "dpop_key_mismatch"
        )
        for jwt in (
            proof(first["key"], token_url, method="GET"),
            proof(first["key"], token_url + "/wrong"),
            proof(first["key"], token_url, issued=int(time.time()) - 120),
        ):
            assert exchange(first, dpop=jwt, expected=400)["error"] == "invalid_request"
        self.stage = "initial binding and receipt recovery"
        tokens = exchange(first)
        bound(tokens, first)
        swapped = dict(
            first,
            key=wrong_key,
            public=b64(
                wrong_key.public_key().public_bytes(
                    serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint
                )
            ),
        )
        assert exchange(swapped, expected=400)["error_description"] == "dpop_key_mismatch"
        assert exchange(first)["refresh_token"] == tokens["refresh_token"]
        assert exchange(first, dpop=False, expected=400)["error_description"] == "dpop_proof_required"
        assert (
            exchange(first, dpop=proof(wrong_key, token_url), expected=400)["error_description"] == "dpop_key_mismatch"
        )
        self.restart()
        assert exchange(first)["refresh_token"] == tokens["refresh_token"]
        self.stage = "bound renewal rejects missing/wrong/replayed/malformed proofs"
        assert refresh(first, tokens, dpop=False, expected=400)["error_description"] == "dpop_proof_required"
        assert (
            refresh(first, tokens, dpop=proof(wrong_key, token_url), expected=400)["error_description"]
            == "dpop_key_mismatch"
        )
        for jwt in (
            proof(first["key"], token_url, method="GET"),
            proof(first["key"], token_url + "/wrong"),
            proof(first["key"], token_url, issued=int(time.time()) - 120),
        ):
            assert refresh(first, tokens, dpop=jwt, expected=400)["error"] == "invalid_request"
        jwt = proof(first["key"], token_url)
        replacement = refresh(first, tokens, dpop=jwt)
        bound(replacement, first)
        assert refresh(first, tokens, dpop=jwt, expected=400)["error"] == "invalid_request"
        assert exchange(first, expected=400)["error_description"] in ("recovery_expired", "session_revoked")
        self.stage = "lost replacement; reuse original after proof window and restart"
        # No refresh rotation grace exists. Also outlive Keycloak's 10s+15s proof window.
        time.sleep(27)
        bound(refresh(first, tokens), first)
        self.restart()
        bound(refresh(first, tokens), first)
        self.stage = "bearer access remains introspectable by unchanged resource boundary"
        response = self.request(
            self.identity + "/realms/nephos/protocol/openid-connect/token/introspect",
            {
                "client_id": "nephos-api-introspection",
                "client_secret": self.introspection_secret,
                "token": replacement["access_token"],
            },
            form=True,
        )
        assert response["active"]

        self.stage = "legacy preservation without bearer-authorized key adoption"
        admin = self.request(
            self.identity + "/realms/master/protocol/openid-connect/token",
            {
                "grant_type": "password",
                "client_id": "admin-cli",
                "username": "fixture",
                "password": self.password,
            },
            form=True,
        )["access_token"]
        admin_headers = {"Authorization": "Bearer " + admin}
        clients = self.request(
            self.identity + "/admin/realms/nephos/clients?clientId=nephos-ios", headers=admin_headers
        )
        client_url = self.identity + "/admin/realms/nephos/clients/" + clients[0]["id"]

        def gate(enabled):
            client = self.request(client_url, headers=admin_headers)
            client["attributes"]["nephos.qr.dpop.required"] = str(enabled).lower()
            self.request(client_url, client, method="PUT", headers=admin_headers, expected=204)

        gate(False)
        legacy = device()
        legacy_tokens = exchange(legacy, dpop=False)
        assert "cnf" not in claims(legacy_tokens["refresh_token"])
        realm_url = self.identity + "/admin/realms/nephos"
        self.stage = "explicit refresh credential expiration"
        self.request(realm_url, {"offlineSessionIdleTimeout": 2}, method="PUT", headers=admin_headers, expected=204)
        expired_legacy = device()
        expired_tokens = exchange(expired_legacy, dpop=False)
        self.request(
            realm_url,
            {"offlineSessionIdleTimeout": 180 * 24 * 60 * 60},
            method="PUT",
            headers=admin_headers,
            expected=204,
        )
        time.sleep(max(0, claims(expired_tokens["refresh_token"])["exp"] + 1 - int(time.time())))
        assert (
            refresh(expired_legacy, expired_tokens, dpop=False, expected=400)["error_description"]
            == "Refresh token expired"
        )

        self.stage = "existing-realm upgrade preserves both legacy and bound sessions"
        for collection in ("policies", "profiles"):
            self.request(
                realm_url + "/client-policies/" + collection,
                {collection: []},
                method="PUT",
                headers=admin_headers,
                expected=204,
            )
        self.request(realm_url, {"offlineSessionIdleTimeout": 0}, method="PUT", headers=admin_headers, expected=204)

        def admin_call(path, data=None, token=None, method=None):
            return self.request(
                self.identity + path,
                data,
                method=method,
                headers={"Authorization": "Bearer " + token},
                expected=204 if method == "PUT" else 200,
            )

        bootstrap.configure_mobile_policy(admin_call, admin, clients[0]["id"])
        bootstrap.configure_mobile_policy(admin_call, admin, clients[0]["id"])
        assert self.request(realm_url, headers=admin_headers)["offlineSessionIdleTimeout"] == 180 * 24 * 60 * 60
        assert (
            self.request(self.origin + "/realms/nephos/nephos-admin/enrollment/config")["persistentLogin"][
                "refreshBinding"
            ]
            == "dpop"
        )
        assert exchange(legacy, dpop=False)["refresh_token"] == legacy_tokens["refresh_token"]
        assert "cnf" not in claims(refresh(legacy, legacy_tokens, dpop=False)["refresh_token"])
        assert refresh(legacy, legacy_tokens, expected=400)["error_description"] == "legacy_session_unbound"
        bound(refresh(first, tokens), first)

        self.stage = "strict rotation misconfiguration is recoverable and cannot burn durable authority"
        realm_url = self.identity + "/admin/realms/nephos"
        self.request(
            realm_url,
            {"revokeRefreshToken": True, "refreshTokenMaxReuse": 0},
            method="PUT",
            headers=admin_headers,
            expected=204,
        )
        assert refresh(first, tokens, expected=503)["error_description"] == "persistent_login_configuration"
        self.request(realm_url, {"revokeRefreshToken": False}, method="PUT", headers=admin_headers, expected=204)
        bound(refresh(first, tokens), first)

        self.stage = "incompatible inactivity configuration preserves durable authority"
        for timeout in (0, 30 * 24 * 60 * 60):
            self.request(
                realm_url, {"offlineSessionIdleTimeout": timeout}, method="PUT", headers=admin_headers, expected=204
            )
            assert refresh(first, tokens, expected=503)["error_description"] == "persistent_login_configuration"
        self.request(
            realm_url,
            {"offlineSessionIdleTimeout": 180 * 24 * 60 * 60},
            method="PUT",
            headers=admin_headers,
            expected=204,
        )
        bound(refresh(first, tokens), first)

        self.stage = "device revocation and unrelated-device survival"
        second = device()
        second_tokens = exchange(second)
        self.request(
            private + "/users/" + subject + "/devices/" + claims(second_tokens["access_token"])["sid"],
            method="DELETE",
            headers=headers,
            expected=204,
        )
        assert refresh(second, second_tokens, expected=400)["error_description"] == "Offline user session not found"
        bound(refresh(first, tokens), first)
        self.stage = "DPoP-authenticated remote sign-out through RFC7009 revocation"
        third = device()
        third_tokens = exchange(third)
        form = {"client_id": "nephos-ios", "token": third_tokens["refresh_token"], "token_type_hint": "refresh_token"}
        self.request(revoke_url, form, form=True, expected=400)
        self.request(revoke_url, form, form=True, headers={"DPoP": proof(wrong_key, revoke_url)}, expected=400)
        self.request(revoke_url, form, form=True, headers={"DPoP": proof(third["key"], revoke_url)})
        assert refresh(third, third_tokens, expected=400)["error_description"] == "Offline user session not found"
        inactive = self.request(
            self.identity + "/realms/nephos/protocol/openid-connect/token/introspect",
            {
                "client_id": "nephos-api-introspection",
                "client_secret": self.introspection_secret,
                "token": third_tokens["access_token"],
            },
            form=True,
        )
        assert not inactive["active"]
        bound(refresh(first, tokens), first)

        if self.args.check_lifetime_blockers:
            self.stage = "isolated aged-session loading and cleanup investigation"
            aged, untouched = device(), device()
            aged_tokens, untouched_tokens = exchange(aged), exchange(untouched)
            aged_id = str(uuid.UUID(claims(aged_tokens["access_token"])["sid"]))
            untouched_id = str(uuid.UUID(claims(untouched_tokens["access_token"])["sid"]))
            old_timestamp = int(time.time()) - 181 * 24 * 60 * 60

            def age_persisted_sessions():
                # The identity process is stopped: no cached state can overwrite the fixture's age.
                self.identity_sql(
                    "UPDATE offline_user_session SET last_session_refresh = "
                    f"{old_timestamp}, last_session_refresh_coarse = {old_timestamp} "
                    f"WHERE offline_flag = '1' AND user_session_id IN ('{aged_id}', '{untouched_id}')"
                )
                assert (
                    self.identity_sql(
                        "SELECT count(*) FROM offline_user_session WHERE offline_flag = '1' "
                        f"AND user_session_id IN ('{aged_id}', '{untouched_id}')"
                    )
                    == "2"
                )

            self.kc_command.append("--spi-user-sessions--infinispan--session-expiration-period=60")
            self.restart(before_start=age_persisted_sessions)
            # The signed token itself is still fresh; only persisted session inactivity is old.
            assert claims(aged_tokens["refresh_token"])["exp"] > int(time.time())
            error = refresh(aged, aged_tokens, expected=400)
            assert error["error_description"] in ("Offline user session not found", "Offline session not active")
            inactive = self.request(
                self.identity + "/realms/nephos/protocol/openid-connect/token/introspect",
                {
                    "client_id": "nephos-api-introspection",
                    "client_secret": self.introspection_secret,
                    "token": aged_tokens["access_token"],
                },
                form=True,
            )
            assert not inactive["active"]
            # Never refresh/introspect/admin-read the second session: only the scheduled cleaner can remove it.
            self.wait(
                "scheduled deletion of untouched aged offline session",
                lambda: (
                    self.identity_sql(
                        "SELECT count(*) FROM offline_user_session "
                        f"WHERE user_session_id = '{untouched_id}' AND offline_flag = '1'"
                    )
                    == "0"
                ),
                timeout=150,
            )
            assert (
                self.identity_sql(
                    "SELECT count(*) FROM offline_client_session "
                    f"WHERE user_session_id = '{untouched_id}' AND offline_flag = '1'"
                )
                == "0"
            )
            bound(refresh(first, tokens), first)
            print(
                "PASS: time-aged 181-day session is rejected despite fresh signed token; unchanged "
                "introspection is inactive; scheduled cleanup deletes untouched aged user/client rows; "
                "non-aged bound session survives. Host clock unchanged."
            )

        self.stage = "account disablement revokes bound and legacy sessions"
        identity = self.request(private + "/users/" + subject, headers=headers)
        self.request(
            private + "/users/" + subject + "/access",
            {
                "commandId": str(uuid.uuid4()),
                "expectedRevision": identity["revision"],
                "enabled": False,
            },
            method="PUT",
            headers=headers,
        )
        assert refresh(first, tokens, expected=400)["error"] == "invalid_grant"
        assert refresh(legacy, legacy_tokens, dpop=False, expected=400)["error"] == "invalid_grant"
        # Qualify the configured finite inactivity window, not indefinite persistence.
        lifetime = claims(tokens["refresh_token"])["exp"] - claims(tokens["refresh_token"])["iat"]
        assert lifetime == 180 * 24 * 60 * 60
        print(
            "PASS: QR DPoP binding/recovery; proof negatives/replay; same durable credential after "
            "lost response/window/restart; 180-day refresh lifetime; Bearer introspection; legacy no-rebind; "
            "revocation/disablement."
        )
        print("POLICY: sessions expire after 180 days without successful renewal; no absolute offline-session maximum.")

    def run(self):
        self.preflight()
        self.work.mkdir(parents=True, mode=0o700)
        try:
            self.database()
            self.certificates()
            self.services()
            self.qualify()
        except BaseException:
            self.diagnostics()
            raise
        finally:
            self.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--keycloak-dist", required=True, type=Path)
    parser.add_argument("--provider-jar", required=True, type=Path)
    parser.add_argument(
        "--check-lifetime-blockers",
        action="store_true",
        help="Age isolated persisted sessions by 181 days and verify lookup/cleanup barriers.",
    )
    args = parser.parse_args()
    args.simulator = None
    os.umask(0o077)

    def interrupted(signum, frame):
        raise native.FixtureError("Interrupted; cleaning task-owned services.")

    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    Fixture(args).run()


if __name__ == "__main__":
    main()
