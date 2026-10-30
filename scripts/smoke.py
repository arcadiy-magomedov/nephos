#!/usr/bin/env python3
"""Exercise real development services. Never run against a production realm."""

import base64
import json
from pathlib import Path
import secrets
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

ROOT = Path(__file__).resolve().parents[1]
ENV = dict(line.split("=", 1) for line in (ROOT / ".env").read_text().splitlines() if line and not line.startswith("#"))
API = "http://localhost:18080"
IDENTITY = "http://localhost:18081"
GRAFANA = "http://localhost:13000"


def request(url, *, data=None, token=None, basic=None, method=None, headers=None, expected=200):
    request_headers = dict(headers or {})
    if token:
        request_headers["Authorization"] = "Bearer " + token
    if basic:
        request_headers["Authorization"] = "Basic " + base64.b64encode(basic.encode()).decode()
    if isinstance(data, dict):
        data = json.dumps(data).encode()
        request_headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, method=method, headers=request_headers)
    try:
        with urllib.request.urlopen(req, timeout=10) as response:
            status, body = response.status, response.read()
    except urllib.error.HTTPError as error:
        status, body = error.code, error.read()
    if status != expected:
        raise AssertionError(f"{method or 'GET'} {urllib.parse.urlsplit(url).path}: expected {expected}, got {status}")
    if not body:
        return None
    try:
        return json.loads(body)
    except json.JSONDecodeError:
        return body.decode()


def wait(description, check, timeout=90):
    deadline = time.monotonic() + timeout
    last_error = None
    while time.monotonic() < deadline:
        try:
            result = check()
            if result:
                print("PASS:", description)
                return result
        except (AssertionError, urllib.error.URLError, OSError) as error:
            last_error = error
        time.sleep(1)
    raise AssertionError(f"Timed out: {description}; last error: {last_error}")


def token_for(realm, values):
    return request(
        f"{IDENTITY}/realms/{realm}/protocol/openid-connect/token",
        data=urllib.parse.urlencode(values).encode(),
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )["access_token"]


def admin_token():
    return token_for(
        "master",
        {
            "client_id": "admin-cli",
            "grant_type": "password",
            "username": "admin",
            "password": ENV["KEYCLOAK_ADMIN_PASSWORD"],
        },
    )


def sql(statement, **variables):
    args = [
        "docker",
        "compose",
        "exec",
        "-T",
        "postgres",
        "psql",
        "-U",
        "postgres",
        "-d",
        "library",
        "-v",
        "ON_ERROR_STOP=1",
        "--quiet",
    ]
    for key, value in variables.items():
        args += ["-v", f"{key}={value}"]
    subprocess.run(args, input=statement, text=True, cwd=ROOT, check=True, capture_output=True)


def check_database_privileges():
    for database, statement in [
        ("storage", "SELECT 1"),
        ("library", "CREATE TABLE forbidden(id int)"),
        ("library", "UPDATE principals SET enabled=false WHERE false"),
    ]:
        result = subprocess.run(
            [
                "docker",
                "compose",
                "exec",
                "-T",
                "postgres",
                "sh",
                "-c",
                'export PGPASSWORD="$LIBRARY_APP_PASSWORD"; exec psql -h 127.0.0.1 -U library_app -d "$1" -v ON_ERROR_STOP=1 -c "$2"',
                "smoke",
                database,
                statement,
            ],
            cwd=ROOT,
            text=True,
            capture_output=True,
        )
        assert result.returncode != 0 and "permission denied" in result.stderr, (
            "Runtime role unexpectedly allowed access"
        )
    print("PASS: runtime credentials cannot cross databases, create schema, or mutate membership")


def main():
    wait("library readiness", lambda: request(API + "/health/library") == "Healthy")
    wait("storage readiness", lambda: request(API + "/health/storage") == "Healthy")
    wait("Keycloak realm", lambda: request(IDENTITY + "/realms/nephos/.well-known/openid-configuration"))
    wait("Grafana readiness", lambda: request(GRAFANA + "/api/health")["database"] == "ok")
    auth = "admin:" + ENV["GRAFANA_PASSWORD"]
    proxy = GRAFANA + "/api/datasources/proxy/uid/"
    metric = urllib.parse.urlencode({"query": "sum(nephos_library_list_requests_total)"})

    def served_pages():
        values = request(proxy + "prometheus/api/v1/query?" + metric, basic=auth)["data"]["result"]
        return float(values[0]["value"][1]) if values else 0

    initial_pages = served_pages()
    request(API + "/v1/libraries", expected=401)
    print("PASS: anonymous access rejected")
    check_database_privileges()

    admin = admin_token()
    admin_url = IDENTITY + "/admin/realms/nephos"
    realm = request(admin_url, token=admin)
    assert realm["registrationAllowed"] is False
    assert realm["browserFlow"] == "nephos-passkeys"
    print("PASS: closed registration and passkey-only browser flow configured")
    client_id = "smoke-" + uuid.uuid4().hex
    client_secret = secrets.token_hex(32)
    request(
        admin_url + "/clients",
        method="POST",
        token=admin,
        expected=201,
        data={
            "clientId": client_id,
            "secret": client_secret,
            "enabled": True,
            "publicClient": False,
            "serviceAccountsEnabled": True,
            "standardFlowEnabled": False,
            "directAccessGrantsEnabled": False,
            "protocol": "openid-connect",
            "protocolMappers": [
                {
                    "name": "api",
                    "protocol": "openid-connect",
                    "protocolMapper": "oidc-audience-mapper",
                    "config": {"included.custom.audience": "nephos-api", "access.token.claim": "true"},
                }
            ],
        },
    )
    internal_id = request(admin_url + "/clients?clientId=" + client_id, token=admin)[0]["id"]
    subject = None
    library_id = str(uuid.uuid4())
    second_id = str(uuid.uuid4())
    hidden_id = str(uuid.uuid4())
    try:
        subject = request(admin_url + f"/clients/{internal_id}/service-account-user", token=admin)["id"]
        token = token_for(
            "nephos",
            {
                "grant_type": "client_credentials",
                "client_id": client_id,
                "client_secret": client_secret,
            },
        )
        request(API + "/v1/libraries", token=token, expected=403)
        sql(
            """
            INSERT INTO principals(subject, enabled) VALUES (:'subject', true);
            INSERT INTO libraries(id, name) VALUES (:'library'::uuid, 'Smoke visible'), (:'hidden'::uuid, 'Smoke hidden');
            INSERT INTO library_members(subject, library_id) VALUES (:'subject', :'library'::uuid);
            """,
            subject=subject,
            library=library_id,
            hidden=hidden_id,
        )
        trace_id = uuid.uuid4().hex
        page = request(
            API + "/v1/libraries", token=token, headers={"traceparent": f"00-{trace_id}-{secrets.token_hex(8)}-01"}
        )
        assert page == {
            "items": [{"id": library_id, "name": "Smoke visible", "isShared": False}],
            "nextCursor": None,
        }, page
        print("PASS: actual Keycloak JWT and PostgreSQL membership isolate libraries")
        sql(
            """
            INSERT INTO libraries(id, name) VALUES (:'second'::uuid, 'Smoke second');
            INSERT INTO library_members(subject, library_id) VALUES (:'subject', :'second'::uuid);
            """,
            subject=subject,
            second=second_id,
        )
        expected_ids = sorted([library_id, second_id])
        first = request(API + "/v1/libraries?limit=1", token=token)
        assert [item["id"] for item in first["items"]] == expected_ids[:1]
        assert first["nextCursor"] == expected_ids[0]
        second = request(API + "/v1/libraries?limit=1&after=" + first["nextCursor"], token=token)
        assert [item["id"] for item in second["items"]] == expected_ids[1:]
        assert second["nextCursor"] is None
        assert request(API + "/v1/libraries?after=" + expected_ids[1], token=token)["items"] == []
        print("PASS: actual SQL keyset pagination has no duplicate or hidden libraries")
        request(API + "/v1/libraries?limit=0", token=token, expected=400)
        sql("UPDATE principals SET enabled=false WHERE subject=:'subject';", subject=subject)
        request(API + "/v1/libraries", token=token, expected=403)
        print("PASS: disablement rejects an already-issued token")
        sql("UPDATE principals SET enabled=true WHERE subject=:'subject';", subject=subject)

        wait("new request metrics stored in Prometheus", lambda: served_pages() > initial_pages)
        healthy_targets = urllib.parse.urlencode({"query": 'up{job="collector-internal"}'})
        wait(
            "Collector self-metrics scrape healthy",
            lambda: any(
                item["value"][1] == "1"
                for item in request(proxy + "prometheus/api/v1/query?" + healthy_targets, basic=auth)["data"]["result"]
            ),
        )
        logs = urllib.parse.urlencode(
            {
                "query": '{service_name="nephos-library"} | trace_id = "' + trace_id + '" |= "Library page served"',
                "limit": 20,
            }
        )
        wait(
            "logs stored in Loki",
            lambda: request(proxy + "loki/loki/api/v1/query_range?" + logs, basic=auth)["data"]["result"],
        )
        trace = wait(
            "request trace stored in Tempo", lambda: request(proxy + "tempo/api/traces/" + trace_id, basic=auth)
        )
        serialized_trace = json.dumps(trace)
        assert '"Npgsql"' in serialized_trace, "Missing database spans in request trace"
        assert '"db.query.text"' not in serialized_trace and '"db.statement"' not in serialized_trace
        print("PASS: request/database trace correlation without raw SQL attributes")

        subprocess.run(["docker", "compose", "stop", "otel-collector"], cwd=ROOT, check=True, capture_output=True)
        try:
            assert [item["id"] for item in request(API + "/v1/libraries", token=token)["items"]] == expected_ids
            print("PASS: collector outage does not block API")
        finally:
            subprocess.run(["docker", "compose", "start", "otel-collector"], cwd=ROOT, check=True, capture_output=True)
        recovery_trace = uuid.uuid4().hex
        request(
            API + "/v1/libraries",
            token=token,
            headers={"traceparent": f"00-{recovery_trace}-{secrets.token_hex(8)}-01"},
        )
        wait(
            "trace collection recovers after Collector restart",
            lambda: request(proxy + "tempo/api/traces/" + recovery_trace, basic=auth),
        )
    finally:
        try:
            if subject:
                sql(
                    """
                    DELETE FROM library_members WHERE subject=:'subject';
                    DELETE FROM principals WHERE subject=:'subject';
                    DELETE FROM libraries WHERE id IN (:'library'::uuid, :'second'::uuid, :'hidden'::uuid);
                    """,
                    subject=subject,
                    library=library_id,
                    second=second_id,
                    hidden=hidden_id,
                )
        finally:
            request(admin_url + f"/clients/{internal_id}", method="DELETE", token=admin_token(), expected=204)
    print("Foundation smoke checks complete. This does not test interactive iOS/passkey enrollment.")


if __name__ == "__main__":
    main()
