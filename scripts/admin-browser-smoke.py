#!/usr/bin/env python3
"""Qualify the real operator browser flow. Never run against a production realm."""

import argparse
import json
import os
from pathlib import Path
import secrets
import subprocess
import uuid

from playwright.sync_api import sync_playwright, expect
import smoke


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-url", default=os.environ.get("NEPHOS_ADMIN_BASE_URL", "http://localhost:18082"))
    parser.add_argument("--screenshots", type=Path)
    parser.add_argument(
        "--native-claims", type=Path, help="Write only verified fixture claims for native policy tests."
    )
    parser.add_argument("--console-container", help="Explicit development console container for native claim export.")
    args = parser.parse_args()
    if args.native_claims and not args.console_container:
        parser.error("--native-claims requires --console-container")
    base = args.base_url.rstrip("/")
    operator_url = smoke.IDENTITY + "/admin/realms/master/users"
    outsider = "admin-browser-" + uuid.uuid4().hex
    outsider_password = secrets.token_urlsafe(32)
    subject = None
    try:
        smoke.request(
            operator_url,
            token=smoke.admin_token(),
            expected=201,
            data={
                "username": outsider,
                "firstName": "Browser",
                "lastName": "Fixture",
                "email": outsider + "@example.test",
                "emailVerified": True,
                "enabled": True,
                "credentials": [{"type": "password", "value": outsider_password, "temporary": False}],
            },
        )
        subject = smoke.request(operator_url + "?exact=true&username=" + outsider, token=smoke.admin_token())[0]["id"]
        operator_role = smoke.request(smoke.IDENTITY + "/admin/realms/master/roles/admin", token=smoke.admin_token())
        smoke.request(
            operator_url + "/" + subject + "/role-mappings/realm",
            token=smoke.admin_token(),
            data=[operator_role],
            expected=204,
        )
        with sync_playwright() as playwright:
            browser = playwright.chromium.launch(headless=True)
            context = browser.new_context()
            page = context.new_page()

            def begin():
                response = page.goto(base + "/")
                assert response.status == 200
                assert "www-authenticate" not in response.headers
                expect(page.locator('nav[aria-label="Main navigation"]')).to_have_count(0)
                page.get_by_role("link", name="Sign in", exact=True).click()
                expect(page.locator("#username")).to_be_visible()
                assert page.url.startswith(smoke.IDENTITY + "/realms/master/")

            begin()
            if args.screenshots:
                args.screenshots.mkdir(parents=True, exist_ok=True)
                page.screenshot(path=str(args.screenshots / "operator-login.png"), full_page=True)
            page.locator("#username").fill(outsider)
            page.locator("#password").fill("deliberately-wrong-test-password")
            page.locator("#kc-login").click()
            expect(page.locator("#password")).to_be_visible()
            assert not page.url.startswith(base + "/")
            page.locator("#username").fill(outsider)
            page.locator("#password").fill(outsider_password)
            page.locator("#kc-login").click()
            page.wait_for_url(base + "/users")
            expect(page.get_by_role("heading", name="Users", exact=True)).to_be_visible()
            cookies = [cookie for cookie in context.cookies(base) if cookie["name"] == "nephos_admin"]
            assert len(cookies) == 1 and cookies[0]["httpOnly"] and cookies[0]["sameSite"] == "Lax"
            assert smoke.ENV["KEYCLOAK_ADMIN_PASSWORD"] not in cookies[0]["value"]
            old_cookies = context.cookies(base)
            if args.native_claims:
                program = """
import json,sys
from admin_web import app,store,provider,CLAIMS,ISSUER,CLIENT_ID
with app.test_request_context():
    key = 'nephos:admin:' + sys.stdin.read()
    data = app.session_interface.serializer.decode(store.get(key))
    initial = data['token']['userinfo']
    token = provider.fetch_access_token(grant_type='refresh_token', refresh_token=data['token']['refresh_token'])
    refreshed = provider.parse_id_token(token, nonce=None, claims_options=CLAIMS, leeway=30)
    assert refreshed['sub'] == initial['sub']
    assert 'nonce' not in refreshed or refreshed['nonce'] == initial['nonce']
    data['token'] = {**token, 'userinfo': dict(refreshed)}
    store.set(key, app.session_interface.serializer.encode(data), ex=store.ttl(key))
    fields = {'iss','aud','azp','sub','nonce','iat','exp','nbf'}
    print(json.dumps({'issuer':ISSUER,'clientID':CLIENT_ID,
        'initial':{k:v for k,v in initial.items() if k in fields},
        'refreshed':{k:v for k,v in refreshed.items() if k in fields}}))
"""
                result = subprocess.run(
                    ["docker", "exec", "-i", args.console_container, "python", "-c", program],
                    input=cookies[0]["value"],
                    text=True,
                    capture_output=True,
                    check=True,
                )
                claims = json.loads(result.stdout)
                descriptor = os.open(args.native_claims, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
                with os.fdopen(descriptor, "w") as output:
                    json.dump(claims, output)
            page.reload()
            expect(page.get_by_role("button", name="Sign out")).to_be_visible()
            if args.screenshots:
                page.screenshot(path=str(args.screenshots / "operator-console.png"), full_page=True)
            denied = context.request.post(base + "/logout", form={}, headers={"Origin": base})
            assert denied.status == 403
            page.reload()
            expect(page.get_by_role("button", name="Sign out")).to_be_visible()
            page.get_by_role("button", name="Sign out").click()
            expect(page.get_by_role("link", name="Sign in", exact=True)).to_be_visible()
            replay = browser.new_context()
            replay.add_cookies(old_cookies)
            replay_page = replay.new_page()
            replay_page.goto(base + "/")
            expect(replay_page.get_by_role("link", name="Sign in", exact=True)).to_be_visible()
            replay.close()

            smoke.request(
                operator_url + "/" + subject + "/role-mappings/realm",
                token=smoke.admin_token(),
                data=[operator_role],
                method="DELETE",
                expected=204,
            )
            # A denied page must not expose navigation when the stylesheet is unavailable.
            page.route(f"{base}/admin-static/admin.css", lambda route: route.abort())
            begin()
            page.locator("#username").fill(outsider)
            page.locator("#password").fill(outsider_password)
            page.locator("#kc-login").click()
            expect(page.get_by_text("This account is not an administrator.", exact=False)).to_be_visible()
            expect(page.locator('nav[aria-label="Main navigation"]')).to_have_count(0)
            context.close()
            browser.close()
        print("PASS: real OIDC browser login, incorrect password, reload, CSRF, logout/replay and operator-role denial")
    finally:
        if subject:
            smoke.request(operator_url + "/" + subject, method="DELETE", token=smoke.admin_token(), expected=204)


if __name__ == "__main__":
    main()
