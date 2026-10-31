#!/usr/bin/env python3
"""Qualify the real operator browser flow. Never run against a production realm."""

import argparse
from pathlib import Path
import secrets
import uuid

from playwright.sync_api import sync_playwright, expect
import smoke


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-url", default="http://localhost:18082")
    parser.add_argument("--screenshots", type=Path)
    args = parser.parse_args()
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
                page.get_by_role("link", name="Sign in", exact=True).click()
                expect(page.locator("#username")).to_be_visible()
                assert page.url.startswith("http://localhost:18081/realms/master/")

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
            page.wait_for_url(base + "/")
            expect(page.get_by_role("heading", name="Nephos local administration")).to_be_visible()
            cookies = [cookie for cookie in context.cookies(base) if cookie["name"] == "nephos_admin"]
            assert len(cookies) == 1 and cookies[0]["httpOnly"] and cookies[0]["sameSite"] == "Lax"
            assert smoke.ENV["KEYCLOAK_ADMIN_PASSWORD"] not in cookies[0]["value"]
            old_cookies = context.cookies(base)
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
            begin()
            page.locator("#username").fill(outsider)
            page.locator("#password").fill(outsider_password)
            page.locator("#kc-login").click()
            expect(page.get_by_text("This account is not an operator.", exact=False)).to_be_visible()
            assert "Nephos local administration" not in page.content()
            context.close()
            browser.close()
        print("PASS: real OIDC browser login, incorrect password, reload, CSRF, logout/replay and operator-role denial")
    finally:
        if subject:
            smoke.request(operator_url + "/" + subject, method="DELETE", token=smoke.admin_token(), expected=204)


if __name__ == "__main__":
    main()
