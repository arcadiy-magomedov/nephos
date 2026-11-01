#!/usr/bin/env python3
"""Verify closed local provisioning and first-login PIN delivery to the operator."""

import urllib.parse
import uuid
import os
import re
import base64
import json
import smoke

base = os.environ.get("NEPHOS_ADMIN_BASE_URL", "http://localhost:18082")
admin_url = smoke.IDENTITY + "/admin/realms/nephos"
smoke.wait("private administration ready", lambda: smoke.request(base + "/"))
assert "Sign in" in smoke.request(base + "/")
smoke.request(smoke.API + "/internal/admin/state", expected=404)
realm = smoke.request(admin_url, token=smoke.admin_token())
if not realm.get("smtpServer"):
    smoke.request(
        admin_url,
        token=smoke.admin_token(),
        method="PUT",
        expected=204,
        data={
            "smtpServer": {"host": "mailpit", "port": "1025", "from": "nephos@localhost"},
        },
    )
admin = smoke.AdminSession(base)
csrf = admin.csrf
username = "enrollment-smoke-" + uuid.uuid4().hex
subject = None


def submit(values, expected=200):
    return admin.request(
        "/",
        data=urllib.parse.urlencode(values).encode(),
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        expected=expected,
    )


try:
    submit({"action": "create", "username": username, "email": username + "@example.test"}, expected=403)
    result = submit({"csrf": csrf, "action": "create", "username": username, "email": username + "@example.test"})
    assert "User and personal library created" in result
    users = smoke.request(admin_url + "/users?exact=true&username=" + username, token=smoke.admin_token())
    subject = users[0]["id"]
    assert not users[0].get("requiredActions")
    receipt = smoke.request(
        smoke.IDENTITY + "/realms/nephos/nephos-admin/request-pin",
        method="POST",
        data={"email": username + "@example.test", "clientId": "nephos-ios"},
    )
    assert set(receipt) == {"expiresIn"}
    pending = smoke.request(
        smoke.IDENTITY + "/realms/nephos/nephos-admin/pin-requests",
        headers={"X-Nephos-Identity-Service-Key": smoke.ENV["IDENTITY_ADMIN_SERVICE_KEY"]},
    )["requests"]
    requested_pin = next(item["pin"] for item in pending if item["email"] == username + "@example.test")
    assert requested_pin in admin.request("/"), "The requested PIN must be delivered through the private console."
    grant = {
        "grant_type": "urn:nephos:params:oauth:grant-type:login-pin",
        "client_id": "nephos-ios",
        "username": username + "@example.test",
        "pin": requested_pin,
        "device_id": str(uuid.uuid4()),
        "device_name": "Disposable full sign-in acceptance",
        "nonce": str(uuid.uuid4()),
        "scope": "openid profile offline_access",
    }
    tokens = smoke.request(
        smoke.IDENTITY + "/realms/nephos/protocol/openid-connect/token",
        data=urllib.parse.urlencode(grant).encode(),
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )
    for token_type in ("access_token", "id_token"):
        encoded = tokens[token_type].split(".")[1]
        claims = json.loads(base64.urlsafe_b64decode(encoded + "=" * (-len(encoded) % 4)))
        assert claims["sub"] == subject, f"{token_type} must identify the provisioned account"
    libraries = smoke.request(smoke.API + "/v1/libraries", token=tokens["access_token"])["items"]
    assert len(libraries) == 1 and libraries[0]["name"] == username + "'s library"
    assert not libraries[0]["isShared"], "PIN login must open the user's own writable library."
    refreshed = smoke.request(
        smoke.IDENTITY + "/realms/nephos/protocol/openid-connect/token",
        data=urllib.parse.urlencode(
            {"grant_type": "refresh_token", "client_id": "nephos-ios", "refresh_token": tokens["refresh_token"]}
        ).encode(),
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )
    assert smoke.request(smoke.API + "/v1/libraries", token=refreshed["access_token"])["items"] == libraries
    result = submit({"csrf": csrf, "action": "issue_pin", "subject": subject})
    assert "One-time PIN issued" in result
    pin = re.search(r"First-login PIN \(shown once\)</h2><p><strong>([0-9]{8})</strong>", result)
    assert pin, "The one-time PIN was not shown to the operator."
    assert "First-login PIN (shown once)" not in admin.request("/"), "The PIN was shown more than once."
    result = submit({"csrf": csrf, "action": "access", "subject": subject})
    assert "Platform membership updated" in result
    smoke.request(smoke.API + "/v1/libraries", token=refreshed["access_token"], expected=401)
    print("PASS: email → private PIN delivery → token subject → own writable library → refresh → revoked access")
finally:
    admin.close()
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
