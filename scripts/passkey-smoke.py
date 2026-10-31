#!/usr/bin/env python3
"""Real Keycloak invitation and Code+PKCE login using Chromium's virtual passkey."""

import base64
import hashlib
import html
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import os
import re
import secrets
import threading
import urllib.parse
import uuid

from playwright.sync_api import sync_playwright

import smoke


class Callback(BaseHTTPRequestHandler):
    def do_GET(self):
        body = b"OIDC callback received"
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass  # Authorization codes must not be written to test output.


def main():
    issuer = smoke.request(smoke.API + "/v1/config")["issuer"]
    base = "http://localhost:18082"
    auth = "admin:" + smoke.ENV["KEYCLOAK_ADMIN_PASSWORD"]
    admin_url = smoke.IDENTITY + "/admin/realms/nephos"
    page_html = smoke.wait("private administration ready", lambda: smoke.request(base + "/", basic=auth))
    csrf = re.search(r'name="csrf" value="([^"]+)"', page_html)[1]
    username = "passkey-smoke-" + uuid.uuid4().hex
    server = ThreadingHTTPServer(("127.0.0.1", 0), Callback)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    callback_host = os.environ.get("NEPHOS_PASSKEY_CALLBACK_HOST", "127.0.0.1")
    callback = f"http://{callback_host}:{server.server_port}/callback"
    subject = client = None

    def submit(values):
        return smoke.request(
            base + "/",
            basic=auth,
            data=urllib.parse.urlencode({"csrf": csrf, **values}).encode(),
            headers={"Content-Type": "application/x-www-form-urlencoded"},
        )

    try:
        submit({"action": "create", "username": username, "email": username + "@example.test"})
        subject = smoke.request(admin_url + "/users?exact=true&username=" + username, token=smoke.admin_token())[0][
            "id"
        ]
        submit({"action": "invite", "subject": subject})

        def delivered():
            return next(
                (
                    message
                    for message in smoke.request("http://localhost:18083/api/v1/messages")["messages"]
                    if any(r["Address"] == username + "@example.test" for r in message["To"])
                ),
                None,
            )

        message = smoke.wait("enrollment email delivered", delivered)
        mail = smoke.request("http://localhost:18083/api/v1/message/" + message["ID"])
        links = re.findall(r'href="([^"]+)"', mail["HTML"])
        invitation = next(html.unescape(link) for link in links if "/login-actions/action-token?" in link)
        smoke.request(
            admin_url + "/clients",
            token=smoke.admin_token(),
            method="POST",
            expected=201,
            data={
                "clientId": username,
                "publicClient": True,
                "enabled": True,
                "standardFlowEnabled": True,
                "directAccessGrantsEnabled": False,
                "redirectUris": [callback],
                "attributes": {"pkce.code.challenge.method": "S256"},
                "protocolMappers": [
                    {
                        "name": "api",
                        "protocol": "openid-connect",
                        "protocolMapper": "oidc-audience-mapper",
                        "config": {"included.custom.audience": "nephos-api", "access.token.claim": "true"},
                    }
                ],
            },
        )
        client = smoke.request(admin_url + "/clients?clientId=" + username, token=smoke.admin_token())[0]["id"]
        with sync_playwright() as runtime:
            browser = (
                runtime.chromium.connect_over_cdp(os.environ["NEPHOS_PASSKEY_BROWSER_CDP"])
                if os.environ.get("NEPHOS_PASSKEY_BROWSER_CDP")
                else runtime.chromium.launch(headless=True)
            )
            context = browser.new_context()
            page = context.new_page()
            page.set_default_timeout(15000)
            session = context.new_cdp_session(page)
            session.send("WebAuthn.enable")
            authenticator = session.send(
                "WebAuthn.addVirtualAuthenticator",
                {
                    "options": {
                        "protocol": "ctap2",
                        "transport": "internal",
                        "hasResidentKey": True,
                        "hasUserVerification": True,
                        "isUserVerified": True,
                        "automaticPresenceSimulation": True,
                    }
                },
            )["authenticatorId"]
            page.on("dialog", lambda dialog: dialog.accept("Nephos acceptance passkey"))
            page.goto(invitation)
            proceed = page.get_by_role("link", name=re.compile("proceed", re.I))
            if proceed.count():
                proceed.click()
            page.get_by_role("button", name=re.compile("^Register", re.I)).click()
            page.locator("#firstName").fill("Acceptance")
            page.locator("#lastName").fill("Fixture")
            page.get_by_role("button", name="Submit", exact=True).click()
            page.get_by_text("Your account has been updated.").wait_for()
            credentials = session.send("WebAuthn.getCredentials", {"authenticatorId": authenticator})["credentials"]
            assert len(credentials) == 1
            print("PASS: known-user invitation enrolls a discoverable user-verified passkey")

            context.clear_cookies()
            verifier = secrets.token_urlsafe(48)
            challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).decode().rstrip("=")
            state = secrets.token_urlsafe(24)
            page.goto(
                issuer
                + "/protocol/openid-connect/auth?"
                + urllib.parse.urlencode(
                    {
                        "client_id": username,
                        "redirect_uri": callback,
                        "response_type": "code",
                        "scope": "openid",
                        "state": state,
                        "code_challenge": challenge,
                        "code_challenge_method": "S256",
                    }
                )
            )
            page.locator("#username").fill(username)
            page.locator("#kc-login").click()
            authenticate = page.get_by_role("button", name=re.compile("Sign in with Passkey", re.I))
            authenticate.click()
            page.wait_for_url(callback + "**")
            returned = urllib.parse.parse_qs(urllib.parse.urlsplit(page.url).query)
            assert returned["state"] == [state]
            token = smoke.token_for(
                "nephos",
                {
                    "grant_type": "authorization_code",
                    "client_id": username,
                    "redirect_uri": callback,
                    "code": returned["code"][0],
                    "code_verifier": verifier,
                },
            )
            assert len(smoke.request(smoke.API + "/v1/libraries", token=token)["items"]) == 1
            submit({"action": "access", "subject": subject})
            smoke.request(smoke.API + "/v1/libraries", token=token, expected=403)
            provider_credentials = smoke.request(
                admin_url + "/users/" + subject + "/credentials", token=smoke.admin_token()
            )
            for credential in provider_credentials:
                if credential["type"] == "webauthn-passwordless":
                    smoke.request(
                        admin_url + "/users/" + subject + "/credentials/" + credential["id"],
                        method="DELETE",
                        token=smoke.admin_token(),
                        expected=204,
                    )
            session.send(
                "WebAuthn.removeCredential",
                {"authenticatorId": authenticator, "credentialId": credentials[0]["credentialId"]},
            )
            context.clear_cookies()
            submit({"action": "invite", "subject": subject})

            def replacement_delivered():
                candidate = delivered()
                return candidate if candidate and candidate["ID"] != message["ID"] else None

            replacement = smoke.wait("operator recovery invitation delivered", replacement_delivered)
            recovery = smoke.request("http://localhost:18083/api/v1/message/" + replacement["ID"])
            recovery_link = next(
                html.unescape(link)
                for link in re.findall(r'href="([^"]+)"', recovery["HTML"])
                if "/login-actions/action-token?" in link
            )
            page.goto(recovery_link)
            proceed = page.get_by_role("link", name=re.compile("proceed", re.I))
            if proceed.count():
                proceed.click()
            page.get_by_role("button", name=re.compile("^Register", re.I)).click()
            page.get_by_text("Your account has been updated.").wait_for()
            assert len(session.send("WebAuthn.getCredentials", {"authenticatorId": authenticator})["credentials"]) == 1
            smoke.request(smoke.API + "/v1/libraries", token=token, expected=403)
            browser.close()
            print(
                "PASS: fresh passkey login, Code+PKCE, API authorization, disablement and operator recovery without enabling platform access"
            )
    finally:
        server.shutdown()
        server.server_close()
        thread.join()
        if client:
            smoke.request(admin_url + "/clients/" + client, method="DELETE", token=smoke.admin_token(), expected=204)
        if subject:
            smoke.sql(
                """
                CREATE TEMP TABLE fixture_libraries AS SELECT library_id FROM library_members WHERE subject=:'subject';
                DELETE FROM library_members WHERE subject=:'subject';
                DELETE FROM principals WHERE subject=:'subject';
                DELETE FROM libraries WHERE id IN (SELECT library_id FROM fixture_libraries);
                """,
                subject=subject,
            )
            smoke.request(admin_url + "/users/" + subject, method="DELETE", token=smoke.admin_token(), expected=204)


if __name__ == "__main__":
    main()
