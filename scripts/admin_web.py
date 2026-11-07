"""Private operator UI: Keycloak OIDC, server-side sessions, and CSRF-protected actions."""

from datetime import datetime, timedelta, timezone
import base64
from concurrent.futures import ThreadPoolExecutor
import io
import json
import os
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
import re

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
import qrcode
from qrcode.image.svg import SvgPathImage
import admin_status
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
app = Flask(__name__, template_folder="admin-templates", static_folder="admin-static")
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
        '<!doctype html><html lang="ru"><meta charset="utf-8"><title>Администрирование недоступно</title>'
        "<h1>Администрирование недоступно</h1>"
        "<p>Хранилище сессий недоступно. Вход и действия администратора временно заблокированы.</p>"
        '<a href="/">Повторить</a></html>',
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


@app.context_processor
def operator_context():
    roles = session.get("token", {}).get("userinfo", {}).get("realm_access", {}).get("roles", [])
    return {
        "operator_authenticated": isinstance(roles, list)
        and "admin" in roles
        and time.time() < session.get("deadline", 0)
    }


@app.template_filter("datetime_ru")
def datetime_ru(value):
    if not value:
        return "Нет данных"
    return (
        datetime.fromisoformat(str(value).replace("Z", "+00:00"))
        .astimezone(timezone.utc)
        .strftime("%d.%m.%Y %H:%M UTC")
    )


@app.template_filter("operation_status")
def operation_status(value):
    return {
        "completed": "Готово",
        "pending": "Выполняется",
        "running": "Выполняется",
        "failed": "Требуется повтор",
        "blocked": "Заблокировано",
        "abandoned": "Отменена после ошибки",
    }.get(value, "Состояние не подтверждено")


@app.template_filter("invitation_status")
def invitation_status(value):
    return {
        "pending": "Ожидает сканирования",
        "used": "Устройство подключено",
        "consumed": "Устройство подключено",
        "expired": "Срок действия истёк",
        "cancelled": "Отменено",
    }.get(value, "Состояние не подтверждено")


@app.template_filter("member_access")
def member_access(value):
    return {
        "owner": "Владелец · прямой участник",
        "member": "Прямой участник",
        "shared": "Предоставленный доступ к медиа",
        "all": "Обмен всеми медиа",
        "subset": "Обмен выбранными медиа",
    }.get(value, "Основание не подтверждено")


@app.template_filter("command_kind")
def command_kind(value):
    return {
        "create": "Создание пользователя",
        "provision": "Создание пользователя",
        "access": "Изменение доступа",
        "profile": "Изменение профиля",
    }.get(value, "Административная операция")


def error_page(message, status):
    return render_template("error.html", message=message), status


@app.before_request
def private_origin():
    if g.get("session_store_unavailable"):
        return session_unavailable()
    if request.method in ("POST", "PUT", "PATCH", "DELETE") and request.headers.get("Origin") != PUBLIC_URL:
        abort(403, description="Действие должно быть отправлено из консоли администратора.")
    if request.host != urllib.parse.urlsplit(PUBLIC_URL).netloc:
        if request.method == "GET":
            return redirect(PUBLIC_URL, code=303)
        abort(403)


@app.before_request
def serialize_session():
    if request.cookies.get(app.config["SESSION_COOKIE_NAME"]):
        lock = store.lock("nephos:admin-request:" + session.sid, timeout=180, blocking_timeout=5)
        if not lock.acquire():
            abort(503, description="Другой запрос администратора ещё выполняется. Повторите позже.")
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
        "default-src 'none'; style-src 'self'; script-src 'self'; connect-src 'self'; img-src 'self' data:; "
        f"form-action 'self' {IDENTITY_PUBLIC_URL}; frame-ancestors 'none'; base-uri 'none'"
    )
    return response


def check_operator(userinfo):
    roles = userinfo.get("realm_access", {}).get("roles") if userinfo else None
    if not isinstance(roles, list) or "admin" not in roles:
        abort(
            403,
            description="Учётная запись не является администратором. Аккаунт медиатеки не предоставляет административные права.",
        )


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
        abort(400, description="Попытка входа истекла. Начните вход заново.")
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
        abort(401, description="Сессия администратора завершена. Войдите заново.")
    if token.get("userinfo", {}).get("iss") != ISSUER:
        session.clear()
        abort(401, description="Настройки авторизации изменились. Войдите заново.")
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


def call(url, data=None, token=None, method=None, service=False, identity_service=False, operator=None):
    headers = {}
    if token:
        headers["Authorization"] = "Bearer " + token
    if service:
        headers["X-Nephos-Service-Key"] = os.environ["SERVICE_KEY"]
    if identity_service:
        headers["X-Nephos-Identity-Service-Key"] = os.environ["IDENTITY_SERVICE_KEY"]
    if operator:
        headers["X-Nephos-Operator-Subject"] = operator
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
    operator_token()
    return redirect("/users", code=303)


def library_call(path, data=None, method=None):
    return call(
        LIBRARY + "/internal/v1/admin" + path,
        data=data,
        method=method,
        service=True,
        operator=session["token"]["userinfo"]["sub"],
    )


def identity_call(path, data=None, method=None):
    return call(IDENTITY + "/realms/nephos/nephos-admin" + path, data=data, method=method, identity_service=True)


def form_values():
    if any(len(request.form.getlist(key)) != 1 for key in request.form):
        abort(400, description="Повторяющиеся поля формы не допускаются.")
    return request.form


def identifier(value):
    return str(uuid.UUID(str(value)))


def revision(value):
    result = int(value)
    if result < 0:
        abort(400, description="Некорректная версия записи.")
    return result


def user_record(subject):
    data = library_call("/users/" + identifier(subject))
    user = data["user"]
    user["login"] = user["login"] or user["subject"]
    user["displayName"] = user["displayName"] or user["login"]
    return data


def library_record(library_id):
    data = library_call("/libraries/" + identifier(library_id))
    library = data["library"]
    library["ownerName"] = library.get("ownerDisplayName") or library.get("ownerLogin")
    library["members"] = [
        {
            **member,
            "access": ("owner" if member["subject"] == library["ownerSubject"] else "member")
            if member["scope"] == "member"
            else ("all" if member["allAssets"] else "subset"),
        }
        for member in data["members"]
    ]
    return library


def page_parameters():
    search = request.args.get("search", "").strip()
    cursor = request.args.get("cursor", "")
    if len(search) > 200 or len(cursor) > 200:
        abort(400, description="Слишком длинный поисковый запрос или указатель страницы.")
    return search, cursor


def page_links(path, parameters, data):
    first = path + "?" + urllib.parse.urlencode(parameters)
    next_url = first + "&" + urllib.parse.urlencode({"cursor": data["nextCursor"]}) if data["nextCursor"] else None
    return {"first_url": first, "next_url": next_url}


@app.get("/users")
def users_page():
    operator_token()
    search, cursor = page_parameters()
    access = request.args.get("access", "")
    if access not in ("", "enabled", "disabled"):
        abort(400, description="Некорректный фильтр доступа.")
    parameters = {"search": search, "limit": 50, "cursor": cursor}
    if access:
        parameters["enabled"] = str(access == "enabled").lower()
    data = library_call("/users?" + urllib.parse.urlencode(parameters))
    for user in data["items"]:
        user["login"] = user["login"] or user["subject"]
    return render_template(
        "users.html",
        section="users",
        data=data,
        search=search,
        access=access,
        **page_links("/users", {"search": search, "access": access}, data),
    )


@app.route("/users/new", methods=["GET", "POST"])
def create_user():
    operator_token()
    if request.method == "GET":
        return render_template("user-form.html", section="users", user=None, values={}, command=str(uuid.uuid4()))
    values = form_values()
    login_value = values["login"].strip().lower()
    name = values["displayName"].strip()
    command = identifier(values["command"])
    if (
        not re.fullmatch(r"[a-z0-9][a-z0-9._-]{0,63}", login_value)
        or not name
        or len(name) > 100
        or any(ord(c) < 32 for c in name)
    ):
        return render_template(
            "user-form.html",
            section="users",
            user=None,
            values=values,
            command=command,
            error="Введите имя и логин: до 64 латинских букв, цифр, точек, дефисов и подчёркиваний.",
        ), 400
    operation = library_call(
        "/operations",
        {
            "id": command,
            "login": login_value,
            "displayName": name,
            "discoverable": values.get("discoverable") == "yes",
            "libraryName": "Личная медиатека",
        },
    )
    operation = wait_operation(operation)
    return redirect("/operations/" + operation["id"], code=303)


def dependency_state(load, description):
    try:
        return load(), None
    except (urllib.error.URLError, TimeoutError):
        logger.warning("Administration detail dependency unavailable", extra={"dependency": description})
        return [], "Не удалось получить " + description + ". Состояние не подтверждено; обновите страницу."


def invitation_record(value):
    return {**value, "id": value["inviteId"], "status": "pending" if value["status"] == "active" else value["status"]}


@app.get("/users/<uuid:subject>")
def user_page(subject):
    operator_token()
    subject = str(subject)
    data = user_record(subject)
    devices, devices_error = dependency_state(
        lambda: identity_call("/users/" + subject + "/devices")["devices"], "устройства"
    )
    invites, invitations_error = dependency_state(
        lambda: identity_call("/users/" + subject + "/invitations")["invitations"], "приглашения"
    )
    return render_template(
        "user.html",
        section="users",
        user=data["user"],
        libraries=data["libraries"],
        memberships=data["memberships"],
        operation=None,
        devices=devices,
        devices_error=devices_error,
        invitations=[invitation_record(item) for item in invites],
        invitations_error=invitations_error,
    )


@app.route("/users/<uuid:subject>/edit", methods=["GET", "POST"])
def edit_user(subject):
    operator_token()
    subject = str(subject)
    user = user_record(subject)["user"]
    if request.method == "GET":
        return render_template("user-form.html", section="users", user=user, values={}, command=str(uuid.uuid4()))
    values = form_values()
    name = values["displayName"].strip()
    if not name or len(name) > 100 or any(ord(c) < 32 for c in name):
        return render_template(
            "user-form.html",
            section="users",
            user=user,
            values=values,
            command=identifier(values["command"]),
            error="Имя не может быть пустым или длиннее 100 символов.",
        ), 400
    operation = library_call(
        "/users/" + subject + "/profile",
        {
            "commandId": identifier(values["command"]),
            "expectedRevision": revision(values["revision"]),
            "displayName": name,
            "discoverable": values.get("discoverable") == "yes",
        },
    )
    return redirect("/operations/" + operation["id"], code=303)


@app.route("/users/<uuid:subject>/access", methods=["GET", "POST"])
def user_access(subject):
    operator_token()
    subject = str(subject)
    user = user_record(subject)["user"]
    if request.method == "POST":
        values = form_values()
        if values["enabled"] not in ("true", "false"):
            abort(400, description="Некорректное состояние доступа.")
        operation = library_call(
            "/users/" + subject + "/access",
            {
                "commandId": identifier(values["command"]),
                "expectedRevision": revision(values["revision"]),
                "enabled": values["enabled"] == "true",
            },
        )
        return redirect("/operations/" + operation["id"], code=303)
    return render_template(
        "confirm.html",
        section="users",
        heading=("Отключить" if user["enabled"] else "Включить") + " доступ " + user["displayName"] + "?",
        explanation="Все пользовательские сессии и QR будут отозваны. Медиа сохраняется."
        if user["enabled"]
        else "Подключение будет доступно после проверки сервера. Отозванные сессии не восстанавливаются.",
        fields={
            "revision": user["revision"],
            "enabled": str(not user["enabled"]).lower(),
            "command": str(uuid.uuid4()),
        },
        button="Отключить доступ" if user["enabled"] else "Включить доступ",
        destructive=user["enabled"],
        return_url="/users/" + subject,
    )


@app.route("/users/<uuid:subject>/devices/<uuid:device>/revoke", methods=["GET", "POST"])
def revoke_device(subject, device):
    operator_token()
    subject, device = str(subject), str(device)
    devices = identity_call("/users/" + subject + "/devices")["devices"]
    record = next((item for item in devices if item["id"] == device), None)
    if request.method == "POST":
        form_values()
        if record:
            identity_call("/users/" + subject + "/devices/" + device, method="DELETE")
        flash("Устройство отозвано. Остальные устройства продолжают работать.")
        return redirect("/users/" + subject, code=303)
    if not record:
        abort(404, description="Устройство уже отозвано или не найдено.")
    return render_template(
        "confirm.html",
        section="users",
        heading="Отозвать " + record["name"] + "?",
        explanation="Устройство потеряет доступ. Медиа и доступ других устройств сохраняются.",
        fields={},
        button="Отозвать доступ",
        destructive=True,
        return_url="/users/" + subject,
    )


@app.route("/users/<uuid:subject>/invitations/new", methods=["GET", "POST"])
def create_invitation(subject):
    operator_token()
    subject = str(subject)
    user = user_record(subject)["user"]
    if not user["enabled"]:
        abort(409, description="Аккаунт отключён. Подключение устройств недоступно.")
    if request.method == "GET":
        return render_template(
            "invitation.html", section="users", user=user, invitation=None, command=str(uuid.uuid4())
        )
    values = form_values()
    invitation = identity_call("/users/" + subject + "/invitations", {"commandId": identifier(values["command"])})
    svg_data = None
    if "qr" in invitation:
        output = io.BytesIO()
        qrcode.make(json.dumps(invitation["qr"], separators=(",", ":")), image_factory=SvgPathImage, border=4).save(
            output
        )
        svg_data = base64.b64encode(output.getvalue()).decode("ascii")
    return render_template(
        "invitation.html", section="users", user=user, invitation=invitation_record(invitation), qr_data=svg_data
    )


@app.get("/users/<uuid:subject>/invitations/<uuid:invite>/status")
def invitation_state(subject, invite):
    operator_token()
    items = identity_call("/users/" + str(subject) + "/invitations")["invitations"]
    record = next((item for item in items if item["inviteId"] == str(invite)), None)
    if not record:
        abort(404, description="Приглашение не найдено.")
    return invitation_record(record)


@app.post("/users/<uuid:subject>/invitations/<uuid:invite>/cancel")
def cancel_invitation(subject, invite):
    operator_token()
    form_values()
    identity_call("/users/" + str(subject) + "/invitations/" + str(invite), method="DELETE")
    flash("Приглашение отменено. Этот QR больше не предоставляет доступ.")
    return redirect("/users/" + str(subject), code=303)


@app.get("/operations/<uuid:operation_id>")
def operation_page(operation_id):
    operator_token()
    operation = library_call("/operations/" + str(operation_id))
    operation["error"] = operation_error(operation.get("errorCode"))
    return render_template("operation.html", section="users", operation=operation)


def operation_error(value):
    return (
        {
            "identity_conflict": "Учётная запись или её версия конфликтует с операцией. Проверьте данные.",
            "identity_unavailable": "Сервер авторизации недоступен. Сервер повторит операцию.",
            "identity_rejected": "Сервер авторизации отклонил операцию. Проверьте состояние аккаунта.",
            "persistence_unavailable": "Хранилище состояния недоступно. Операция будет повторена.",
        }.get(value, "Операция не завершена; проверьте актуальное состояние.")
        if value
        else None
    )


@app.get("/operations")
def operations_page():
    operator_token()
    _search, cursor = page_parameters()
    status = request.args.get("status", "")
    if status not in ("", "pending", "running", "failed", "completed", "abandoned"):
        abort(400, description="Некорректное состояние операции.")
    parameters = {"cursor": cursor, "limit": 50}
    if status:
        parameters["status"] = status
    data = library_call("/operations?" + urllib.parse.urlencode(parameters))
    for operation in data["items"]:
        operation["error"] = operation_error(operation.get("errorCode"))
    return render_template(
        "operations.html",
        section="overview",
        data=data,
        status=status,
        **page_links("/operations", {"status": status}, data),
    )


@app.post("/operations/<uuid:operation_id>/retry")
def retry_operation(operation_id):
    operator_token()
    form_values()
    library_call("/operations/" + str(operation_id) + "/retry", method="POST")
    return redirect("/operations/" + str(operation_id), code=303)


@app.route("/operations/<uuid:operation_id>/abandon", methods=["GET", "POST"])
def abandon_operation(operation_id):
    operator_token()
    operation_id = str(operation_id)
    operation = library_call("/operations/" + operation_id)
    if operation["kind"] == "provision" or operation["status"] not in ("failed", "abandoned"):
        abort(409, description="Можно отменить только завершившееся ошибкой изменение профиля или доступа.")
    if request.method == "POST":
        form_values()
        library_call("/operations/" + operation_id + "/abandon", method="POST")
        return redirect("/operations/" + operation_id, code=303)
    return render_template(
        "confirm.html",
        section="users",
        heading="Отменить незавершённое изменение?",
        explanation="Существующий доступ не восстанавливается. После отмены откройте карточку пользователя и отправьте новое исправленное действие.",
        fields={},
        button="Отменить изменение",
        destructive=True,
        return_url="/operations/" + operation_id,
    )


@app.get("/libraries")
def libraries_page():
    operator_token()
    search, cursor = page_parameters()
    data = library_call("/libraries?" + urllib.parse.urlencode({"search": search, "cursor": cursor, "limit": 50}))
    for item in data["items"]:
        item["ownerName"] = item.get("ownerDisplayName") or item.get("ownerLogin")
    return render_template(
        "libraries.html",
        section="libraries",
        data=data,
        search=search,
        **page_links("/libraries", {"search": search}, data),
    )


@app.get("/libraries/<uuid:library_id>")
def library_page(library_id):
    operator_token()
    return render_template("library.html", section="libraries", library=library_record(library_id))


@app.route("/libraries/new", methods=["GET", "POST"])
@app.route("/libraries/<uuid:library_id>/edit", methods=["GET", "POST"])
def library_form(library_id=None):
    operator_token()
    library = library_record(library_id) if library_id else None
    if request.method == "POST":
        values = form_values()
        name = values["name"].strip()
        if not name or len(name) > 200 or any(ord(c) < 32 for c in name):
            abort(400, description="Введите название медиатеки до 200 символов.")
        if library:
            library_call(
                "/libraries/" + str(library_id) + "/rename",
                {"name": name, "expectedRevision": revision(values["revision"])},
            )
        else:
            library_id = identifier(values["command"])
            library_call("/libraries", {"id": library_id, "name": name, "subject": identifier(values["subject"])})
        flash("Медиатека сохранена.")
        return redirect("/libraries/" + str(library_id), code=303)
    owners = library_call(
        "/users?" + urllib.parse.urlencode({"cursor": request.args.get("ownersCursor", ""), "limit": 100})
    )
    next_url = (
        "/libraries/new?" + urllib.parse.urlencode({"ownersCursor": owners["nextCursor"]})
        if owners["nextCursor"]
        else None
    )
    return render_template(
        "library-form.html",
        section="libraries",
        library=library,
        heading="Изменить название" if library else "Создать медиатеку",
        command=str(uuid.uuid4()),
        values={},
        owners=owners["items"],
        owners_next_url=next_url,
    )


@app.route("/libraries/<uuid:library_id>/owner", methods=["GET", "POST"])
def library_owner(library_id):
    operator_token()
    library = library_record(library_id)
    if library["ownerSubject"]:
        abort(409, description="Владелец уже назначен. Перенос владения недоступен.")
    if request.method == "POST":
        values = form_values()
        library_call(
            "/libraries/" + str(library_id) + "/owner",
            {
                "subject": identifier(values["subject"]),
                "expectedRevision": revision(values["revision"]),
            },
        )
        flash("Владелец назначен. Права на файлы не изменены.")
        return redirect("/libraries/" + str(library_id), code=303)
    owners = [item for item in library["members"] if item["scope"] in ("member", "direct")]
    return render_template(
        "library-form.html",
        section="libraries",
        library=library,
        owner_assignment=True,
        heading="Назначить владельца",
        command=str(uuid.uuid4()),
        values={},
        owners=owners,
    )


@app.get("/services")
def services_page():
    operator_token()
    return render_template("services.html", section="services", services=admin_status.services())


@app.get("/overview")
def overview_page():
    operator_token()
    summary = library_call("/summary")
    operations = [
        item
        for status in ("pending", "running", "failed")
        for item in library_call("/operations?" + urllib.parse.urlencode({"limit": 10, "status": status}))["items"]
    ]
    for operation in operations:
        operation["error"] = operation_error(operation.get("errorCode"))
    targets = [
        (
            os.environ.get("ADMIN_STORAGE_URL", "http://storage-api:8080"),
            [
                ("Объём медиатома", "capacityBytes", "GiB"),
                ("Доступное место", "freeBytes", "GiB"),
                ("Проверка загрузок", "verifying", "Файлы"),
                ("Публикация загрузок", "outboxPending", "Сообщения"),
            ],
        )
    ]
    faces = os.environ.get("ADMIN_FACES_URL")
    if faces:
        targets.append(
            (
                faces,
                [
                    ("Лица: очередь", "queued", "Файлы"),
                    ("Лица: выполняются", "running", "Файлы"),
                    ("Лица: ошибки", "error", "Файлы"),
                ],
            )
        )

    def read_metrics(target):
        url, definitions = target
        try:
            data = call(url.rstrip("/") + "/internal/v1/admin/summary", service=True)
            observed = data["checkedAt"]
            return [
                {
                    "label": label,
                    "unit": unit,
                    "value": round(data[key] / (1024**3), 2) if unit == "GiB" else data[key],
                    "observedAt": observed,
                    "state": "Нет данных",
                }
                for label, key, unit in definitions
            ]
        except (urllib.error.URLError, KeyError, TimeoutError):
            logger.warning("Administration summary unavailable")
            return [
                {"label": label, "unit": unit, "value": None, "observedAt": None, "state": "Недоступно"}
                for label, _key, unit in definitions
            ]

    with ThreadPoolExecutor(max_workers=len(targets)) as executor:
        metrics = [metric for group in executor.map(read_metrics, targets) for metric in group]
    metrics.append(
        {
            "label": "Публикация анализа",
            "unit": "Задания",
            "value": summary["publicationPending"],
            "observedAt": summary["checkedAt"],
            "state": "Нет данных",
        }
    )
    metrics.extend(admin_status.broker_metrics())
    return render_template(
        "overview.html",
        section="overview",
        counts={
            "users": summary["userCount"],
            "enabledUsers": summary["enabledUserCount"],
            "libraries": summary["libraryCount"],
        },
        operations=operations,
        metrics=metrics,
        pending_count=summary["operationsPending"],
        failed_count=summary["operationsFailed"],
        checked_at=summary["checkedAt"],
        identity_synced_at=summary.get("identitySyncedAt"),
        identity_stale=not summary.get("identitySyncedAt")
        or (
            datetime.now(timezone.utc) - datetime.fromisoformat(summary["identitySyncedAt"].replace("Z", "+00:00"))
        ).total_seconds()
        > 90,
    )


@app.post("/")
def action():
    token = operator_token()
    form = form_values()
    action = form["action"]
    if action == "create":
        login_value = form["username"].strip().lower()
        operation = library_call(
            "/operations",
            {
                "id": form.get("command") or str(uuid.uuid5(uuid.NAMESPACE_URL, "nephos-user:" + login_value)),
                "login": login_value,
                "displayName": login_value,
                "discoverable": True,
                "libraryName": login_value + "'s library",
            },
        )
        operation = wait_operation(operation)
        if operation["status"] != "completed":
            return redirect("/operations/" + operation["id"], code=303)
        if form.get("email"):
            call(
                IDENTITY + "/admin/realms/nephos/users/" + operation["subject"],
                {"email": form["email"].strip()},
                token=token,
                method="PUT",
            )
        flash("Пользователь и личная медиатека созданы.")
        return redirect("/users/" + operation["subject"], code=303)
    if action in ("access", "directory"):
        subject = identifier(form["subject"])
        user = user_record(subject)["user"]
        command = {"commandId": form.get("command") or str(uuid.uuid4()), "expectedRevision": user["revision"]}
        if action == "access":
            command["enabled"] = form.get("enabled") == "yes"
            operation = library_call("/users/" + subject + "/access", command)
        else:
            command.update(displayName=user["displayName"], discoverable=form.get("discoverable") == "yes")
            operation = library_call("/users/" + subject + "/profile", command)
        operation = wait_operation(operation)
        return redirect("/operations/" + operation["id"], code=303)
    elif action == "library":
        library_id = form.get("command") or str(uuid.uuid4())
        library_call(
            "/libraries",
            {"id": identifier(library_id), "name": form["name"].strip(), "subject": identifier(form["subject"])},
        )
        return redirect("/libraries/" + library_id, code=303)
    else:
        abort(400, description="Неизвестное административное действие.")


def wait_operation(operation):
    deadline = time.monotonic() + 15
    while operation["status"] in ("pending", "running") and time.monotonic() < deadline:
        time.sleep(0.25)
        operation = library_call("/operations/" + operation["id"])
    return operation


@app.errorhandler(CSRFError)
def csrf_error(error):
    return error_page("Форма истекла или не прошла проверку. Обновите страницу перед повтором.", 403)


@app.errorhandler(HTTPException)
def http_error(error):
    return error_page(error.description, error.code)


@app.errorhandler(urllib.error.HTTPError)
def provider_error(error):
    logger.warning("Administration provider rejected a request", extra={"http_status": error.code})
    if error.code in (400, 404, 409, 429):
        return error_page(
            {
                400: "Проверьте введённые значения. Действие отклонено сервером.",
                404: "Запись не найдена. Откройте актуальное состояние.",
                409: "Данные изменились или логин уже занят. Откройте актуальное состояние перед повтором.",
                429: "Слишком много запросов. Подождите и повторите действие.",
            }[error.code],
            error.code,
        )
    return error_page(
        f"Сервер отклонил запрос ({error.code}). Проверьте актуальное состояние перед повтором.",
        502,
    )


@app.errorhandler(OAuthError)
@app.errorhandler(JoseError)
def authentication_error(error):
    logger.warning("Operator authentication failed", extra={"error_type": type(error).__name__})
    session.clear()
    return error_page("Не удалось проверить вход или сессия авторизации завершена. Войдите заново.", 401)


@app.errorhandler(RequestException)
@app.errorhandler(urllib.error.URLError)
@app.errorhandler(RedisError)
@app.errorhandler(LockError)
def dependency_error(error):
    logger.error("Administration dependency unavailable", extra={"error_type": type(error).__name__})
    return error_page(
        "Зависимость администрирования недоступна. Результат действия не подтверждён. "
        "Проверьте состояние сервисов и операции перед повтором.",
        503,
    )


@app.errorhandler(ValueError)
def invalid_input(error):
    logger.warning("Invalid administration input", extra={"error_type": type(error).__name__})
    return error_page("Введённые значения некорректны. Проверьте форму и повторите.", 400)
