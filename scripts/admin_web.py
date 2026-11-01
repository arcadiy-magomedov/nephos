"""Private operator UI: Keycloak OIDC, server-side sessions, and CSRF-protected actions."""

from datetime import timedelta
import json
import os
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

from authlib.integrations.base_client.errors import OAuthError
from authlib.integrations.flask_client import OAuth
from flask import Flask, Response, abort, flash, g, redirect, render_template, request, session
from flask_session.redis import RedisSessionInterface
from flask_wtf.csrf import CSRFError, CSRFProtect
from joserfc.errors import JoseError
from redis import Redis
from redis.backoff import NoBackoff
from redis.exceptions import LockError, RedisError
from redis.retry import Retry
from requests.exceptions import RequestException
import requests
from werkzeug.exceptions import HTTPException

from admin_config import CALLBACK, CLIENT_ID, IDENTITY_PUBLIC_URL, ISSUER, PUBLIC_URL
from admin_telemetry import instrument, logger, propagator, tracer
from opentelemetry.trace import SpanKind

IDENTITY = os.environ["IDENTITY_URL"].rstrip("/")
LIBRARY = os.environ["LIBRARY_ADMIN_URL"].rstrip("/")
BACKCHANNEL = IDENTITY + "/realms/master"
SESSION_SECONDS = 8 * 60 * 60
store = Redis(
    host=os.environ.get("ADMIN_SESSION_HOST", "admin-sessions"),
    password=os.environ["ADMIN_SESSION_STORE_PASSWORD"],
    socket_timeout=3,
    socket_connect_timeout=3,
    retry=Retry(NoBackoff(), 0),
    max_connections=16,
)
app = Flask(__name__, template_folder="admin-templates")
app.config.update(
    SECRET_KEY=os.environ["ADMIN_SESSION_SECRET"],
    TRUSTED_HOSTS=[urllib.parse.urlsplit(PUBLIC_URL).hostname, "localhost", "127.0.0.1", "[::1]"],
    MAX_CONTENT_LENGTH=8192,
    MAX_FORM_PARTS=20,
    SESSION_TYPE="redis",
    SESSION_REDIS=store,
    SESSION_KEY_PREFIX="nephos:admin:",
    SESSION_COOKIE_NAME="nephos_admin",
    SESSION_COOKIE_HTTPONLY=True,
    SESSION_COOKIE_SECURE=PUBLIC_URL.startswith("https:"),
    SESSION_COOKIE_SAMESITE="Lax",
    SESSION_REFRESH_EACH_REQUEST=False,
    PERMANENT_SESSION_LIFETIME=timedelta(seconds=SESSION_SECONDS),
    WTF_CSRF_FIELD_NAME="csrf",
)


def session_unavailable():
    return Response(
        "<!doctype html><title>Administration unavailable</title><h1>Administration unavailable</h1>"
        "<p>The session service is unavailable. Sign-in and administration are temporarily blocked.</p>"
        '<a href="/">Try again</a>',
        status=503,
        content_type="text/html; charset=utf-8",
        headers={"Cache-Control": "no-store"},
    )


class AvailableSessions(RedisSessionInterface):
    def load_current(self):
        return super().open_session(app, request)

    def persist(self, value):
        super().save_session(app, value, Response())
        value.modified = False

    def open_session(self, app, request):
        try:
            return super().open_session(app, request)
        except RedisError:
            logger.error("Administration session store unavailable")
            g.session_store_unavailable = True
            return self.make_null_session(app)

    def save_session(self, app, session, response):
        try:
            super().save_session(app, session, response)
        except RedisError:
            logger.error("Administration session could not be persisted")
            response.status_code = 503
            response.headers.pop("Location", None)
            response.set_data(session_unavailable().get_data())
            response.headers["Content-Type"] = "text/html; charset=utf-8"


app.session_interface = AvailableSessions(app, client=store, key_prefix="nephos:admin:")
instrument(app)
oauth = OAuth(app)
provider = oauth.register(
    "keycloak",
    client_id=CLIENT_ID,
    client_secret=os.environ["ADMIN_OIDC_CLIENT_SECRET"],
    server_metadata_url=BACKCHANNEL + "/.well-known/openid-configuration",
    client_kwargs={"scope": "openid profile", "code_challenge_method": "S256", "timeout": 10},
)
CLAIMS = {
    "iss": {"essential": True, "value": ISSUER},
    "aud": {"essential": True, "value": CLIENT_ID},
    "exp": {"essential": True},
    "sub": {"essential": True},
}


def error_page(message, status):
    return render_template("error.html", message=message), status


@app.before_request
def private_origin():
    if g.get("session_store_unavailable"):
        return session_unavailable()
    if request.method in ("POST", "PUT", "PATCH", "DELETE") and request.headers.get("Origin") != PUBLIC_URL:
        abort(403, description="This action must originate from the administration page.")
    if request.host != urllib.parse.urlsplit(PUBLIC_URL).netloc:
        if request.method == "GET":
            return redirect(PUBLIC_URL, code=303)
        abort(403)


@app.before_request
def serialize_session():
    if request.cookies.get(app.config["SESSION_COOKIE_NAME"]):
        lock = store.lock("nephos:admin-request:" + session.sid, timeout=180, blocking_timeout=5)
        if not lock.acquire():
            abort(503, description="Another administration request is in progress. Try again shortly.")
        g.admin_session_lock = lock
        current = app.session_interface.load_current()
        session.clear()
        session.update(current)
        session.sid = current.sid
        session.modified = False


@app.teardown_request
def release_session(error):
    lock = g.pop("admin_session_lock", None)
    if lock:
        try:
            lock.release()
        except RedisError:
            logger.error("Administration session lock could not be released; it will expire")


CSRFProtect(app)


@app.after_request
def security_headers(response):
    response.headers["Cache-Control"] = "no-store"
    response.headers["Pragma"] = "no-cache"
    response.headers["Referrer-Policy"] = "strict-origin"
    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["Content-Security-Policy"] = (
        "default-src 'none'; style-src 'unsafe-inline'; "
        f"form-action 'self' {IDENTITY_PUBLIC_URL}; frame-ancestors 'none'; base-uri 'none'"
    )
    return response


def check_operator(userinfo):
    roles = userinfo.get("realm_access", {}).get("roles") if userinfo else None
    if not isinstance(roles, list) or "admin" not in roles:
        abort(403, description="This account is not an operator. A photo-library account cannot administer Nephos.")


def validate_metadata():
    metadata = provider.load_server_metadata()
    if metadata.get("issuer") != ISSUER:
        raise OAuthError("invalid_issuer")
    if metadata.get("authorization_endpoint") != ISSUER + "/protocol/openid-connect/auth":
        raise OAuthError("invalid_authorization_endpoint")


@app.get("/login")
def login():
    if session.get("token") and time.time() < session.get("deadline", 0):
        return redirect("/", code=303)
    validate_metadata()
    session.clear()
    session["login_started"] = time.time()
    app.session_interface.regenerate(session)
    return provider.authorize_redirect(CALLBACK, prompt="login")


@app.get("/oauth/callback")
def callback():
    if time.time() - session.get("login_started", 0) > 600:
        abort(400, description="This sign-in attempt has expired. Start again.")
    validate_metadata()
    token = provider.authorize_access_token(claims_options=CLAIMS, leeway=30)
    userinfo = token.get("userinfo")
    check_operator(userinfo)
    session.clear()
    session["token"] = {**token, "userinfo": dict(userinfo)}
    session["nonce"] = userinfo["nonce"]
    session["deadline"] = time.time() + SESSION_SECONDS
    app.session_interface.regenerate(session)
    return redirect("/", code=303)


def operator_token():
    token = session.get("token")
    if not token or time.time() >= session.get("deadline", 0):
        session.clear()
        abort(401, description="Your administration session has expired. Sign in again.")
    if token.get("userinfo", {}).get("iss") != ISSUER:
        session.clear()
        abort(401, description="Identity settings have changed. Sign in again.")
    check_operator(token.get("userinfo"))
    if token.get("expires_at", 0) <= time.time() + 30:
        previous_userinfo = token["userinfo"]
        token = provider.fetch_access_token(grant_type="refresh_token", refresh_token=token["refresh_token"])
        # OIDC refresh ID tokens normally omit nonce (Core 12.2).
        userinfo = provider.parse_id_token(token, nonce=None, claims_options=CLAIMS, leeway=30)
        if (
            not userinfo
            or userinfo.get("sub") != previous_userinfo["sub"]
            or ("nonce" in userinfo and userinfo["nonce"] != session["nonce"])
            or ("auth_time" in userinfo and userinfo["auth_time"] != previous_userinfo.get("auth_time"))
        ):
            raise OAuthError("invalid_refresh_identity")
        check_operator(userinfo)
        token = {**token, "userinfo": dict(userinfo)}
        session["token"] = token
        app.session_interface.persist(session)
    return token["access_token"]


@app.post("/logout")
def logout():
    token = session.get("token")
    session.clear()
    app.session_interface.persist(session)
    if token and token.get("refresh_token"):
        response = requests.post(
            BACKCHANNEL + "/protocol/openid-connect/logout",
            data={
                "client_id": CLIENT_ID,
                "client_secret": os.environ["ADMIN_OIDC_CLIENT_SECRET"],
                "refresh_token": token["refresh_token"],
            },
            timeout=10,
        )
        response.raise_for_status()
    return redirect("/", code=303)


def call(url, data=None, token=None, method=None, service=False, identity_service=False):
    headers = {}
    if token:
        headers["Authorization"] = "Bearer " + token
    if service:
        headers["X-Nephos-Service-Key"] = os.environ["SERVICE_KEY"]
    if identity_service:
        headers["X-Nephos-Identity-Service-Key"] = os.environ["IDENTITY_SERVICE_KEY"]
    if data is not None:
        headers["Content-Type"] = "application/json"
        data = json.dumps(data).encode()
    with tracer.start_as_current_span(
        "administration dependency", kind=SpanKind.CLIENT, record_exception=False, set_status_on_exception=False
    ):
        propagator.inject(headers)
        with urllib.request.urlopen(
            urllib.request.Request(url, data=data, headers=headers, method=method), timeout=20
        ) as response:
            body = response.read()
            return json.loads(body) if body else None


@app.get("/")
def index():
    if not session.get("token"):
        return render_template("login.html")
    token = operator_token()
    users = call(IDENTITY + "/admin/realms/nephos/users?max=1000", token=token)
    state = call(LIBRARY + "/internal/v1/admin/state", service=True)
    pin_requests = call(IDENTITY + "/realms/nephos/nephos-admin/pin-requests", identity_service=True)["requests"]
    issued_pin = session.pop("issued_pin", None)
    if issued_pin and issued_pin["expires"] <= time.time():
        issued_pin = None
    device_list = session.pop("device_list", None)
    device_subject = session.pop("device_subject", None)
    return render_template(
        "administration.html",
        users=users,
        state=state,
        principals={p["subject"]: p["enabled"] for p in state["principals"]},
        issued_pin=issued_pin,
        pin_requests=pin_requests,
        device_list=device_list,
        device_subject=device_subject,
    )


@app.post("/")
def action():
    token = operator_token()
    form = request.form
    if any(len(form.getlist(key)) != 1 for key in form):
        abort(400, description="Duplicate form fields are not accepted.")
    action = form["action"]
    if action == "create":
        username = form["username"].strip()
        if not username or len(username) > 100 or not form["email"].strip():
            abort(400, description="Provide a username and email.")
        call(
            IDENTITY + "/admin/realms/nephos/users",
            token=token,
            data={
                "username": username,
                "email": form["email"].strip(),
                "enabled": True,
            },
        )
        users = call(
            IDENTITY + "/admin/realms/nephos/users?exact=true&username=" + urllib.parse.quote(username), token=token
        )
        subject = users[0]["id"]
        call(
            IDENTITY + f"/admin/realms/nephos/users/{subject}",
            {"requiredActions": []},
            token=token,
            method="PUT",
        )
        call(
            LIBRARY + "/internal/v1/admin/principals",
            {"subject": subject, "enabled": True, "displayName": username, "discoverable": True},
            service=True,
        )
        call(
            LIBRARY + "/internal/v1/admin/libraries",
            {"id": str(uuid.uuid4()), "name": username + "'s library", "subject": subject},
            service=True,
        )
        message = "User and personal library created. The user can request a sign-in PIN with their email."
    elif action == "issue_pin":
        subject = str(uuid.UUID(form["subject"]))
        issued = call(
            IDENTITY + f"/realms/nephos/nephos-admin/users/{subject}/pin",
            token=None,
            method="POST",
            identity_service=True,
        )
        session["issued_pin"] = {"pin": issued["pin"], "expires": time.time() + issued["expiresIn"]}
        message = "One-time PIN issued. Copy it now and give it to the user in person; it is not emailed."
    elif action == "access":
        subject = str(uuid.UUID(form["subject"]))
        enabled = form.get("enabled") == "yes"
        identity_user = call(IDENTITY + "/admin/realms/nephos/users/" + subject, token=token)
        if not enabled:
            identity_user["enabled"] = False
            call(IDENTITY + "/admin/realms/nephos/users/" + subject, identity_user, token, "PUT")
            call(
                IDENTITY + f"/realms/nephos/nephos-admin/users/{subject}/pin",
                method="DELETE",
                identity_service=True,
            )
            devices = call(IDENTITY + f"/realms/nephos/nephos-admin/users/{subject}/devices", identity_service=True)[
                "devices"
            ]
            for device in devices:
                call(
                    IDENTITY + f"/realms/nephos/nephos-admin/users/{subject}/devices/{device['id']}",
                    method="DELETE",
                    identity_service=True,
                )
        else:
            identity_user["enabled"] = True
            call(IDENTITY + "/admin/realms/nephos/users/" + subject, identity_user, token, "PUT")
        call(
            LIBRARY + "/internal/v1/admin/principals",
            {"subject": subject, "enabled": enabled},
            service=True,
        )
        message = "Platform membership updated. Disabled accounts have all device sessions revoked."
    elif action == "devices":
        subject = str(uuid.UUID(form["subject"]))
        session["device_list"] = call(
            IDENTITY + f"/realms/nephos/nephos-admin/users/{subject}/devices", identity_service=True
        )["devices"]
        session["device_subject"] = subject
        message = "Device sessions loaded."
    elif action == "revoke_device":
        subject = str(uuid.UUID(form["subject"]))
        device_id = str(uuid.UUID(form["device_id"]))
        call(
            IDENTITY + f"/realms/nephos/nephos-admin/users/{subject}/devices/{device_id}",
            method="DELETE",
            identity_service=True,
        )
        session["device_list"] = call(
            IDENTITY + f"/realms/nephos/nephos-admin/users/{subject}/devices", identity_service=True
        )["devices"]
        session["device_subject"] = subject
        message = "Device session revoked. Its refresh token is no longer valid."
    elif action == "library":
        if not form["name"].strip() or len(form["name"]) > 200:
            abort(400, description="Provide a library name of at most 200 characters.")
        call(
            LIBRARY + "/internal/v1/admin/libraries",
            {"id": str(uuid.uuid4()), "name": form["name"], "subject": str(uuid.UUID(form["subject"]))},
            service=True,
        )
        message = "Library created."
    elif action == "directory":
        subject = str(uuid.UUID(form["subject"]))
        identity = call(IDENTITY + "/admin/realms/nephos/users/" + subject, token=token)
        state = call(LIBRARY + "/internal/v1/admin/state", service=True)
        principal = next((p for p in state["principals"] if p["subject"] == subject), None)
        if principal is None:
            abort(409, description="Provision platform access before publishing this user in the directory.")
        call(
            LIBRARY + "/internal/v1/admin/principals",
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
        abort(400, description="Unknown administration action.")
    flash(message)
    return redirect("/", code=303)


@app.errorhandler(CSRFError)
def csrf_error(error):
    return error_page("This form has expired or could not be verified. Reload the page before trying again.", 403)


@app.errorhandler(HTTPException)
def http_error(error):
    return error_page(error.description, error.code)


@app.errorhandler(urllib.error.HTTPError)
def provider_error(error):
    logger.warning("Administration provider rejected a request", extra={"http_status": error.code})
    return error_page(
        f"Provider request failed ({error.code}). Inspect existing state before retrying provisioning.",
        502,
    )


@app.errorhandler(OAuthError)
@app.errorhandler(JoseError)
def authentication_error(error):
    logger.warning("Operator authentication failed", extra={"error_type": type(error).__name__})
    session.clear()
    return error_page("Sign-in could not be verified or your identity session has ended. Start sign-in again.", 401)


@app.errorhandler(RequestException)
@app.errorhandler(urllib.error.URLError)
@app.errorhandler(RedisError)
@app.errorhandler(LockError)
def dependency_error(error):
    logger.error("Administration dependency unavailable", extra={"error_type": type(error).__name__})
    return error_page(
        "An administration dependency is unavailable. No automatic retry was made. "
        "Check service health and inspect existing state before retrying an action.",
        503,
    )


@app.errorhandler(ValueError)
def invalid_input(error):
    logger.warning("Invalid administration input", extra={"error_type": type(error).__name__})
    return error_page("The submitted values are invalid. Check the form and try again.", 400)
