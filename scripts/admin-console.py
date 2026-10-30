#!/usr/bin/env python3
"""Loopback-published operator console. Never put this service behind public ingress."""

import base64
import hmac
import html
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
import secrets
import urllib.error
import urllib.parse
import urllib.request
import uuid
from admin_telemetry import instrument, propagator, tracer
from opentelemetry.trace import SpanKind

PASSWORD = os.environ["ADMIN_PASSWORD"]
IDENTITY = os.environ["IDENTITY_URL"]
LIBRARY = os.environ["LIBRARY_ADMIN_URL"]
CSRF = secrets.token_urlsafe(32)


def call(url, data=None, token=None, method=None, service=False):
    headers = {}
    if token:
        headers["Authorization"] = "Bearer " + token
    if service:
        headers["X-Nephos-Service-Key"] = os.environ["SERVICE_KEY"]
    if isinstance(data, (dict, list)):
        headers["Content-Type"] = "application/json"
        data = json.dumps(data).encode()
    elif isinstance(data, bytes):
        headers["Content-Type"] = "application/x-www-form-urlencoded"
    with tracer.start_as_current_span(
        "administration dependency", kind=SpanKind.CLIENT, record_exception=False, set_status_on_exception=False
    ):
        propagator.inject(headers)
        with urllib.request.urlopen(
            urllib.request.Request(url, data=data, headers=headers, method=method), timeout=20
        ) as response:
            body = response.read()
            return json.loads(body) if body else None


def admin_token():
    return call(
        IDENTITY + "/realms/master/protocol/openid-connect/token",
        urllib.parse.urlencode(
            {"client_id": "admin-cli", "grant_type": "password", "username": "admin", "password": PASSWORD}
        ).encode(),
    )["access_token"]


class Console(BaseHTTPRequestHandler):
    def send_response(self, code, message=None):
        self.status_code = code
        super().send_response(code, message)

    def log_message(self, *_):
        pass  # The request wrapper logs bounded fields without raw URLs.

    def authenticated(self):
        expected = "Basic " + base64.b64encode(("admin:" + PASSWORD).encode()).decode()
        if not hmac.compare_digest(self.headers.get("Authorization", ""), expected):
            self.send_response(401)
            self.send_header("WWW-Authenticate", 'Basic realm="Nephos local administration"')
            self.end_headers()
            return False
        return True

    def page(self, message=""):
        token = admin_token()
        users = call(IDENTITY + "/admin/realms/nephos/users?max=1000", token=token)
        state = call(LIBRARY + "/internal/admin/state", service=True)
        principal_state = {p["subject"]: p["enabled"] for p in state["principals"]}
        options = "".join(
            f'<option value="{html.escape(u["id"])}">{html.escape(u["username"])}</option>' for u in users
        )
        entries = "".join(
            f"<li>{html.escape(u['username'])} — platform access: {principal_state.get(u['id'], False)}</li>"
            for u in users
        )
        libraries = "".join(f"<li>{html.escape(v['name'])} ({html.escape(v['id'])})</li>" for v in state["libraries"])
        csrf = f'<input type="hidden" name="csrf" value="{CSRF}">'
        body = f"""<!doctype html><html lang="en"><meta charset="utf-8"><title>Nephos administration</title>
        <style>body{{font:16px system-ui;max-width:850px;margin:3em auto;padding:1em}}form{{padding:1em;border:1px solid #999;margin:1em 0}}input,button,select{{font:inherit;margin:.3em}}label{{display:block}}</style>
        <h1>Nephos local administration</h1><p>{html.escape(message)}</p>
        <p>This private console provisions known accounts and libraries. Self-registration is disabled.
        Configure SMTP in Keycloak before sending passwordless enrollment invitations.</p>
        <h2>Known users</h2><ul>{entries}</ul>
        <form method="post">{csrf}<input type="hidden" name="action" value="create">
        <label>Username <input name="username" required maxlength="100"></label>
        <label>Email <input name="email" type="email" required></label>
        <button>Create known user and personal library</button></form>
        <form method="post">{csrf}<input type="hidden" name="action" value="invite">
        <label>Known user <select name="subject">{options}</select></label>
        <button>Send passkey enrollment / recovery invitation</button></form>
        <form method="post">{csrf}<input type="hidden" name="action" value="access">
        <label>User <select name="subject">{options}</select></label>
        <label><input type="checkbox" name="enabled" value="yes">Enable platform access</label>
        <button>Apply (unchecked disables existing tokens immediately)</button></form>
        <form method="post">{csrf}<input type="hidden" name="action" value="directory">
        <label>User <select name="subject">{options}</select></label>
        <label><input type="checkbox" name="discoverable" value="yes" checked>Visible in the known-user sharing directory</label>
        <button>Update sharing-directory visibility</button></form>
        <h2>Libraries</h2><ul>{libraries}</ul>
        <form method="post">{csrf}<input type="hidden" name="action" value="library">
        <label>Name <input name="name" maxlength="200" required></label>
        <label>Owner <select name="subject">{options}</select></label>
        <button>Create library</button></form>
        <p>Identity credential removal, SMTP and provider recovery policies remain in the private Keycloak console.
        No application endpoint deletes originals or retention holds.</p></html>""".encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header(
            "Content-Security-Policy",
            "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'",
        )
        self.end_headers()
        self.wfile.write(body)

    @instrument
    def do_GET(self):
        if not self.authenticated():
            return
        if self.path != "/":
            self.send_error(404)
            return
        try:
            self.page()
        except (urllib.error.URLError, OSError) as error:
            self.send_error(503, "Administration dependency unavailable: " + type(error).__name__)

    @instrument
    def do_POST(self):
        if not self.authenticated():
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if self.path != "/" or length <= 0 or length > 8192:
                self.send_error(400)
                return
            form = {k: v[0] for k, v in urllib.parse.parse_qs(self.rfile.read(length).decode()).items()}
            if not hmac.compare_digest(form.get("csrf", ""), CSRF):
                self.send_error(403)
                return
            token = admin_token()
            action = form["action"]
            if action == "create":
                username = form["username"].strip()
                call(
                    IDENTITY + "/admin/realms/nephos/users",
                    token=token,
                    data={
                        "username": username,
                        "email": form["email"],
                        "enabled": True,
                        "requiredActions": ["webauthn-register-passwordless"],
                    },
                )
                users = call(
                    IDENTITY + "/admin/realms/nephos/users?exact=true&username=" + urllib.parse.quote(username),
                    token=token,
                )
                subject = users[0]["id"]
                call(
                    LIBRARY + "/internal/admin/principals",
                    {"subject": subject, "enabled": True, "displayName": username, "discoverable": True},
                    service=True,
                )
                call(
                    LIBRARY + "/internal/admin/libraries",
                    {"id": str(uuid.uuid4()), "name": username + "'s library", "subject": subject},
                    service=True,
                )
                message = "User and library created. Send an enrollment invitation next."
            elif action == "invite":
                subject = str(uuid.UUID(form["subject"]))
                call(
                    IDENTITY + f"/admin/realms/nephos/users/{subject}/execute-actions-email?lifespan=900",
                    data=["webauthn-register-passwordless"],
                    token=token,
                    method="PUT",
                )
                message = "Single-use passkey enrollment link sent; expires in 15 minutes. Treat mailbox access as enrollment authority."
            elif action == "access":
                call(
                    LIBRARY + "/internal/admin/principals",
                    {"subject": str(uuid.UUID(form["subject"])), "enabled": form.get("enabled") == "yes"},
                    service=True,
                )
                message = "Platform membership updated."
            elif action == "library":
                call(
                    LIBRARY + "/internal/admin/libraries",
                    {"id": str(uuid.uuid4()), "name": form["name"], "subject": str(uuid.UUID(form["subject"]))},
                    service=True,
                )
                message = "Library created."
            elif action == "directory":
                subject = str(uuid.UUID(form["subject"]))
                identity = call(IDENTITY + "/admin/realms/nephos/users/" + subject, token=token)
                state = call(LIBRARY + "/internal/admin/state", service=True)
                principal = next((p for p in state["principals"] if p["subject"] == subject), None)
                if principal is None:
                    self.send_error(409, "Provision platform access before publishing this user in the directory.")
                    return
                call(
                    LIBRARY + "/internal/admin/principals",
                    {
                        "subject": subject,
                        "enabled": principal["enabled"],
                        "displayName": identity["username"],
                        "discoverable": form.get("discoverable") == "yes",
                    },
                    service=True,
                )
                message = "Sharing directory updated."
            else:
                self.send_error(400)
                return
            self.page(message)
        except urllib.error.HTTPError as error:
            self.send_error(
                502,
                f"Provider request failed ({error.code}). Check SMTP for invitations; inspect existing state before retrying provisioning.",
            )
        except (urllib.error.URLError, OSError, ValueError, KeyError) as error:
            self.send_error(400, "Action failed: " + type(error).__name__)


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", 8080), Console).serve_forever()
