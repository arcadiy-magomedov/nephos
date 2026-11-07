#!/usr/bin/env python3
"""Qualify persistent administrator actions against a disposable real stack."""

import os
import re
import urllib.parse
import uuid

import smoke

base = os.environ.get("NEPHOS_ADMIN_BASE_URL", "http://localhost:18082")
admin_url = smoke.IDENTITY + "/admin/realms/nephos"
smoke.wait("private administration ready", lambda: smoke.request(base + "/"))
assert "Войти" in smoke.request(base + "/")
smoke.request(smoke.API + "/internal/admin/state", expected=404)
username = "admin-smoke-" + uuid.uuid4().hex
subject = None


def field(page, name):
    return re.search(r'name="' + name + r'" value="([^"]+)"', page)[1]


def submit(admin, path, values, expected=200):
    return admin.request(
        path,
        data=urllib.parse.urlencode({"csrf": admin.csrf, **values}).encode(),
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        expected=expected,
    )


def completed(admin, page):
    operation = re.search(r"Номер операции: ([0-9a-f-]{36})", page)[1]
    smoke.wait(
        "durable administration operation completed", lambda: "Готово" in admin.request("/operations/" + operation)
    )


with smoke.AdminSession(base) as admin:
    try:
        page = admin.request("/users/new")
        command = field(page, "command")
        values = {"command": command, "login": username, "displayName": "Qualification user", "discoverable": "yes"}
        smoke.request(
            base + "/users/new",
            data=urllib.parse.urlencode(values).encode(),
            headers={"Origin": base, "Content-Type": "application/x-www-form-urlencoded"},
            expected=403,
        )
        completed(admin, submit(admin, "/users/new", values))
        users = smoke.request(admin_url + "/users?exact=true&username=" + username, token=smoke.admin_token())
        assert len(users) == 1 and users[0]["enabled"] and not users[0].get("requiredActions")
        assert not users[0].get("email"), "QR account creation must not require email."
        subject = users[0]["id"]
        completed(admin, submit(admin, "/users/new", values))
        assert len(smoke.request(admin_url + "/users?exact=true&username=" + username, token=smoke.admin_token())) == 1
        page = admin.request("/users/" + subject)
        assert "Личная медиатека" in page and "Qualification user" in page
        assert "Устройства не подключены" in page
        page = admin.request("/users/" + subject + "/edit")
        completed(
            admin,
            submit(
                admin,
                "/users/" + subject + "/edit",
                {
                    "command": field(page, "command"),
                    "revision": field(page, "revision"),
                    "displayName": "Renamed <user>",
                    "discoverable": "yes",
                },
            ),
        )
        assert "Renamed &lt;user&gt;" in admin.request("/users/" + subject)
        assert "Renamed &lt;user&gt;" in admin.request("/users?search=" + urllib.parse.quote("Renamed"))
        page = admin.request("/users/" + subject + "/invitations/new")
        issued = submit(admin, "/users/" + subject + "/invitations/new", {"command": field(page, "command")})
        assert 'src="data:image/svg+xml;base64,' in issued, "A real QR must be rendered."
        monitor = re.search(r'data-url="([^"]+)"', issued)[1]
        state = admin.request(monitor)
        assert state["status"] == "pending" and "secret" not in state
        invite = state["id"]
        replay = submit(admin, "/users/" + subject + "/invitations/new", {"command": field(page, "command")})
        assert 'src="data:image/svg+xml;base64,' not in replay, "A repeated issuance must not reveal the secret again."
        submit(admin, "/users/" + subject + "/invitations/" + invite + "/cancel", {})
        assert admin.request(monitor)["status"] == "cancelled"
        page = admin.request("/libraries/new")
        created = submit(
            admin,
            "/libraries/new",
            {"command": field(page, "command"), "name": "Additional library", "subject": subject},
        )
        assert "Additional library" in created and "Renamed &lt;user&gt;" in created
        library_id = re.search(r'href="/libraries/([0-9a-f-]{36})/edit"', created)[1]
        page = admin.request("/libraries/" + library_id + "/edit")
        renamed = submit(
            admin,
            "/libraries/" + library_id + "/edit",
            {
                "command": field(page, "command"),
                "revision": field(page, "revision"),
                "name": "Renamed library",
            },
        )
        assert "Renamed library" in renamed
        assert "Renamed library" in admin.request("/libraries?search=Renamed")
        for path, heading in (("/overview", "Обзор"), ("/services", "Состояние сервисов")):
            assert heading in admin.request(path)
        page = admin.request("/users/" + subject + "/access")
        completed(
            admin,
            submit(
                admin,
                "/users/" + subject + "/access",
                {
                    "command": field(page, "command"),
                    "revision": field(page, "revision"),
                    "enabled": "false",
                },
            ),
        )
        assert not smoke.request(admin_url + "/users/" + subject, token=smoke.admin_token())["enabled"]
        assert "Аккаунт отключён" in admin.request("/users/" + subject)
        print(
            "PASS: persistent create/replay/profile/search, real QR issuance/cancel, library create/rename, overview/services and disable"
        )
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
            smoke.request(admin_url + "/users/" + subject, method="DELETE", token=smoke.admin_token(), expected=204)
