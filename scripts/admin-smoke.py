#!/usr/bin/env python3
"""Verify closed local provisioning and delivery of passkey enrollment invitations."""

import urllib.parse
import uuid
import os
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
    assert "User and library created" in result
    users = smoke.request(admin_url + "/users?exact=true&username=" + username, token=smoke.admin_token())
    subject = users[0]["id"]
    assert users[0]["requiredActions"] == ["webauthn-register-passwordless"]
    result = submit({"csrf": csrf, "action": "invite", "subject": subject})
    assert "Single-use passkey enrollment link sent" in result

    def delivered():
        response = smoke.request("http://localhost:18083/api/v1/messages")
        return next(
            (
                message
                for message in response["messages"]
                if any(recipient["Address"] == username + "@example.test" for recipient in message["To"])
            ),
            None,
        )

    mail = smoke.wait("passkey enrollment invitation delivered to the local-only inbox", delivered)
    result = submit({"csrf": csrf, "action": "access", "subject": subject})
    assert "Platform membership updated" in result
    print("PASS: authenticated/CSRF-protected local provisioning, known user, personal library, invite and disablement")
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
