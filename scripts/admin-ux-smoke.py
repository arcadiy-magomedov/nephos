#!/usr/bin/env python3
"""Exercise the real console with mouse, keyboard and mobile reflow."""

import base64
import json
import os
import re
import urllib.parse
import uuid

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from playwright.sync_api import sync_playwright, expect
import smoke


def enroll_device(subject, name):
    private = smoke.IDENTITY + "/realms/nephos/nephos-admin"
    config = smoke.request(private + "/enrollment/config")
    origin = urllib.parse.urlsplit(config["origin"])
    forwarded = {
        "X-Forwarded-Proto": origin.scheme,
        "X-Forwarded-Host": origin.netloc,
        "X-Forwarded-Port": str(origin.port or 443),
    }
    invite = smoke.request(
        private + "/users/" + subject + "/invitations",
        data={"commandId": str(uuid.uuid4())},
        headers={**forwarded, "X-Nephos-Identity-Service-Key": smoke.ENV["IDENTITY_ADMIN_SERVICE_KEY"]},
        expected=201,
    )
    key = ec.generate_private_key(ec.SECP256R1())

    def encode(value):
        return base64.urlsafe_b64encode(value).rstrip(b"=").decode()

    public = encode(
        key.public_key().public_bytes(serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint)
    )
    request_id = str(uuid.uuid4())
    challenge = smoke.request(
        private + "/enrollment/challenge",
        data={
            "inviteId": invite["inviteId"],
            "requestId": request_id,
            "clientId": config["clientId"],
            "publicKey": public,
        },
        headers=forwarded,
    )
    signed = base64.urlsafe_b64decode(challenge["challenge"] + "==")
    token_url = smoke.IDENTITY + "/realms/nephos/protocol/openid-connect/token"
    token = smoke.request(
        token_url,
        data=urllib.parse.urlencode(
            {
                "grant_type": config["grantType"],
                "client_id": config["clientId"],
                "invite_id": invite["inviteId"],
                "invite_secret": invite["qr"]["secret"],
                "request_id": request_id,
                "public_key": public,
                "challenge_id": challenge["challengeId"],
                "signature": encode(key.sign(signed, ec.ECDSA(hashes.SHA256()))),
                "device_name": name,
                "nonce": str(uuid.uuid4()),
                "scope": "openid offline_access",
            }
        ).encode(),
        headers={**forwarded, "Content-Type": "application/x-www-form-urlencoded"},
    )
    claims = token_claims(token["id_token"])
    assert claims.get("iss") == config["issuer"] and claims.get("sub") == subject
    return token_url, token["refresh_token"], forwarded, config["issuer"]


def token_claims(token):
    return json.loads(base64.urlsafe_b64decode(token.split(".")[1] + "=="))


def refresh_device(token_url, token, headers, expected):
    return smoke.request(
        token_url,
        data=urllib.parse.urlencode(
            {"grant_type": "refresh_token", "client_id": "nephos-ios", "refresh_token": token}
        ).encode(),
        headers={**headers, "Content-Type": "application/x-www-form-urlencoded"},
        expected=expected,
    )


def main():
    base = os.environ.get("NEPHOS_ADMIN_BASE_URL", "http://localhost:18082")
    username = "ux-" + uuid.uuid4().hex
    subject = None
    admin_url = smoke.IDENTITY + "/admin/realms/nephos/users"
    try:
        with sync_playwright() as playwright:
            browser = playwright.chromium.launch()
            page = browser.new_page()
            errors = []
            page.on("pageerror", lambda error: errors.append(type(error).__name__))
            page.goto(base)
            page.get_by_role("link", name="Sign in", exact=True).click()
            page.locator("#username").fill("admin")
            page.locator("#password").fill(smoke.ENV["KEYCLOAK_ADMIN_PASSWORD"])
            page.locator("#kc-login").click()
            page.wait_for_url(base + "/users")
            page.get_by_role("link", name="Create user", exact=True).click()
            page.set_viewport_size({"width": 375, "height": 812})
            cancel, create = (
                page.get_by_role("link", name="Cancel", exact=True).bounding_box(),
                page.get_by_role("button", name="Create", exact=True).bounding_box(),
            )
            assert abs(cancel["x"] - create["x"]) < 1 and abs(cancel["width"] - create["width"]) < 1
            assert cancel["y"] < create["y"]
            page.set_viewport_size({"width": 1280, "height": 900})
            page.get_by_label("Name", exact=True).fill("UX qualification")
            page.get_by_label("Username", exact=True).fill(username)
            page.get_by_role("button", name="Create", exact=True).click()
            if "/operations/" in page.url:
                for _ in range(30):
                    if page.get_by_text("Completed", exact=True).is_visible():
                        break
                    page.get_by_role("link", name="Refresh status", exact=True).click()
                    page.wait_for_timeout(500)
                expect(page.get_by_text("Completed", exact=True)).to_be_visible()
                page.get_by_role("link", name="Open user", exact=True).click()
            records = smoke.request(admin_url + "?exact=true&username=" + username, token=smoke.admin_token())
            subject = records[0]["id"]
            expect(page.get_by_role("heading", name="UX qualification", exact=True)).to_be_visible()
            page.get_by_role("button", name="Connect device", exact=True).click()
            dialog = page.get_by_role("dialog", name="Connect device")
            expect(dialog.get_by_role("img", name="Single-use QR code for signing in")).to_be_visible()
            close = dialog.get_by_role("link", name="Close dialog")
            cancel = dialog.get_by_role("button", name="Cancel QR code")
            expect(close).to_be_focused()
            page.keyboard.press("Tab")
            expect(cancel).to_be_focused()
            page.keyboard.press("Tab")
            expect(close).to_be_focused()
            page.keyboard.press("Shift+Tab")
            expect(cancel).to_be_focused()
            bounds, action = dialog.bounding_box(), cancel.bounding_box()
            assert abs(bounds["x"] + bounds["width"] / 2 - action["x"] - action["width"] / 2) < 1
            page.keyboard.press("Escape")
            expect(page.get_by_role("button", name="Connect device", exact=True)).to_be_focused()
            expect(page.get_by_text("An existing QR code is still active.", exact=False)).to_be_visible()
            page.get_by_role("button", name="Cancel QR code", exact=True).click()
            expect(page.get_by_text("Invitation cancelled.", exact=False)).to_be_visible()
            state = {"value": "pending"}

            def simulated_status(route):
                route.fulfill(json={"status": state["value"]})

            status_url = "**/invitations/*/status"
            page.route(status_url, simulated_status)
            page.get_by_role("button", name="Connect device", exact=True).click()
            dialog = page.get_by_role("dialog", name="Connect device")
            expect(dialog.get_by_role("img", name="Single-use QR code for signing in")).to_be_visible()
            expect(dialog.get_by_role("link", name="Close dialog")).to_be_focused()
            cancel = dialog.get_by_role("button", name="Cancel QR code")
            cancel.focus()
            expect(cancel).to_be_focused()
            state["value"] = "expired"
            expect(dialog.locator("#invitation-state")).to_have_text("Expired", timeout=10000)
            expect(dialog.locator("#invitation-state")).to_have_class(re.compile("status-warning"))
            expect(dialog.locator("#dialog-description")).to_have_text("The invitation can no longer be used.")
            expect(dialog.locator("#qr-warning")).not_to_be_visible()
            expect(dialog.get_by_role("img", name="Single-use QR code for signing in")).not_to_be_visible()
            finished = dialog.get_by_role("link", name="Close", exact=True)
            expect(finished).to_be_focused()
            finished.click()
            page.unroute(status_url, simulated_status)
            page.get_by_role("button", name="Cancel QR code", exact=True).click()
            expect(page.get_by_text("Invitation cancelled.", exact=False)).to_be_visible()
            token_url, other_token, forwarded, issuer = enroll_device(subject, "Other phone")
            _, selected_token, _, _ = enroll_device(subject, "Selected phone")
            page.reload()
            other_row = page.locator(".device-row").filter(has_text="Other phone")
            selected_row = page.locator(".device-row").filter(has_text="Selected phone")
            expect(other_row).to_be_visible()
            revoke = selected_row.get_by_role("link", name="Revoke device Selected phone")
            revoke.click()
            dialog = page.get_by_role("dialog", name="Revoke device access?")
            expect(dialog.locator(".selected-device")).to_contain_text("Selected phone")
            expect(dialog.locator(".selected-device")).not_to_contain_text("Other phone")
            cancel = dialog.get_by_role("link", name="Cancel", exact=True)
            confirm = dialog.get_by_role("button", name="Revoke device", exact=True)
            expect(cancel).to_be_focused()
            left, right = cancel.bounding_box(), confirm.bounding_box()
            assert abs(right["x"] - left["x"] - left["width"] - 16) < 1
            page.keyboard.press("Escape")
            expect(revoke).to_be_focused()
            for width, height in ((375, 812), (812, 375)):
                page.set_viewport_size({"width": width, "height": height})
                assert page.evaluate("document.documentElement.scrollWidth <= window.innerWidth")
                revoke.click()
                mobile_dialog = page.get_by_role("dialog", name="Revoke device access?")
                expect(mobile_dialog.get_by_role("link", name="Cancel", exact=True)).to_be_focused()
                mobile_confirm = mobile_dialog.get_by_role("button", name="Revoke device", exact=True)
                mobile_confirm.focus()
                expect(mobile_confirm).to_be_focused()
                box = mobile_confirm.bounding_box()
                assert 0 <= box["x"] and box["x"] + box["width"] <= width
                assert 0 <= box["y"] and box["y"] + box["height"] <= height
                page.keyboard.press("Escape")
                expect(revoke).to_be_focused()
            page.set_viewport_size({"width": 1280, "height": 900})
            revoke.click()
            page.get_by_role("dialog", name="Revoke device access?").get_by_role(
                "button", name="Revoke device", exact=True
            ).click()
            expect(page.get_by_text("Device access revoked.", exact=False)).to_be_visible()
            expect(selected_row).not_to_be_visible()
            expect(other_row).to_be_visible()
            refreshed = refresh_device(token_url, other_token, forwarded, 200)
            assert refreshed["refresh_token"]
            for token_type in ("access_token", "id_token"):
                claims = token_claims(refreshed[token_type])
                assert claims.get("iss") == issuer and claims.get("sub") == subject, (
                    "Refreshed token claims are invalid",
                    token_type,
                    sorted(claims),
                )
            refresh_device(token_url, selected_token, forwarded, 400)
            page.get_by_role("link", name="Edit profile", exact=True).click()
            page.get_by_label("Name", exact=True).fill("Updated UX qualification")
            page.get_by_role("button", name="Save", exact=True).click()
            for _ in range(30):
                if page.get_by_text("Completed", exact=True).is_visible():
                    break
                page.get_by_role("link", name="Refresh status", exact=True).click()
                page.wait_for_timeout(500)
            expect(page.get_by_text("Completed", exact=True)).to_be_visible()
            page.get_by_role("link", name="Open user", exact=True).click()
            expect(page.get_by_role("heading", name="Updated UX qualification", exact=True)).to_be_visible()
            page.reload()
            expect(page.get_by_role("heading", name="Updated UX qualification", exact=True)).to_be_visible()
            for path, title in (
                ("/overview", "Overview"),
                ("/users", "Users"),
                ("/libraries", "Libraries"),
                ("/services", "Service status"),
            ):
                page.goto(base + path)
                expect(page.get_by_role("heading", name=title, exact=True)).to_be_visible()
                page.set_viewport_size({"width": 390, "height": 844})
                overflow = page.evaluate(
                    """() => [...document.querySelectorAll('body *')]
                      .filter(element => element.getBoundingClientRect().right > window.innerWidth + 1)
                      .map(element => `${element.tagName}.${element.className}: ${Math.round(element.getBoundingClientRect().right)}`)
                      .slice(0, 12)"""
                )
                assert page.evaluate("document.documentElement.scrollWidth <= window.innerWidth"), (path, overflow)
                expect(page.get_by_role("navigation", name="Main navigation")).to_be_visible()
                page.set_viewport_size({"width": 1280, "height": 900})
            page.goto(base + "/users?search=definitely-no-matches-" + username)
            expect(page.get_by_role("heading", name="No matches", exact=True)).to_be_visible()
            page.get_by_role("link", name="Reset", exact=True).focus()
            page.keyboard.press("Enter")
            expect(page.get_by_role("heading", name="Users", exact=True)).to_be_visible()
            page.get_by_role("button", name="Sign out", exact=True).click()
            expect(page.get_by_role("link", name="Sign in", exact=True)).to_be_visible()
            assert not errors, errors
            browser.close()
        print("PASS: real browser creation, QR, selected-device revocation, profile, keyboard and mobile reflow")
    finally:
        if subject:
            smoke.sql(
                """
                CREATE TEMP TABLE fixture_libraries AS SELECT library_id FROM library_members WHERE subject=:'subject';
                DELETE FROM administration_events WHERE operation_id IN(SELECT id FROM administration_operations WHERE subject=:'subject');
                DELETE FROM administration_operations WHERE subject=:'subject';
                DELETE FROM library_members WHERE subject=:'subject';
                DELETE FROM personal_libraries WHERE subject=:'subject';
                UPDATE libraries SET owner_subject=NULL WHERE owner_subject=:'subject';
                DELETE FROM principals WHERE subject=:'subject';
                DELETE FROM libraries WHERE id IN(SELECT library_id FROM fixture_libraries);
                """,
                subject=subject,
            )
            smoke.request(admin_url + "/" + subject, method="DELETE", token=smoke.admin_token(), expected=204)


if __name__ == "__main__":
    main()
