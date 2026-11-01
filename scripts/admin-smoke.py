#!/usr/bin/env python3
"""Verify closed local provisioning and first-login PIN delivery to the operator."""

import urllib.parse
import uuid
import os
import re
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
    result = submit({"csrf": csrf, "action": "issue_pin", "subject": subject})
    assert "One-time PIN issued" in result
    pin = re.search(r"First-login PIN \(shown once\)</h2><p><strong>([0-9]{8})</strong>", result)
    assert pin, "The one-time PIN was not shown to the operator."
    assert "First-login PIN (shown once)" not in admin.request("/"), "The PIN was shown more than once."
    result = submit({"csrf": csrf, "action": "access", "subject": subject})
    assert "Platform membership updated" in result
    print("PASS: authenticated/CSRF-protected local provisioning, one-time PIN issuance and account disablement")
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
