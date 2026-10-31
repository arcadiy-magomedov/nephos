#!/usr/bin/env python3
"""Verify stored operational metrics, evaluated alerts, dashboard, and broker permissions."""

import subprocess
import json
import secrets
import urllib.parse
import uuid

import smoke

auth = "admin:" + smoke.ENV["GRAFANA_PASSWORD"]
proxy = smoke.GRAFANA + "/api/datasources/proxy/uid/prometheus"


def query(expression):
    return smoke.request(proxy + "/api/v1/query?" + urllib.parse.urlencode({"query": expression}), basic=auth)["data"][
        "result"
    ]


expected_services = {
    "nephos-library",
    "nephos-library-worker",
    "nephos-library-admin",
    "nephos-storage",
    "nephos-storage-worker",
    "nephos-admin-console",
}
smoke.wait(
    "all six core application service heartbeats, allowing optional services",
    lambda: (
        expected_services
        <= {row["metric"]["service"] for row in query("time() - max by(service) (nephos_service_heartbeat) < 60")}
    ),
)
smoke.wait("fresh storage state sampled through Collector", lambda: query("time() - nephos_storage_sampled_at < 60"))
smoke.wait("media volume headroom measured", lambda: query("nephos_storage_free_bytes > 0"))
smoke.wait(
    "per-queue broker backlog metrics",
    lambda: len(query('rabbitmq_queue_messages{queue=~"nephos.assets.(ready|dead)"}')) == 2,
)


def evaluated_alerts():
    groups = smoke.request(proxy + "/api/v1/rules", basic=auth)["data"]["groups"]
    alerts = [rule for group in groups for rule in group["rules"]]
    assert len(alerts) >= 11, "Expected operational alert rules are not loaded"
    unhealthy = [(rule["name"], rule["health"], rule.get("lastError")) for rule in alerts if rule["health"] != "ok"]
    assert not unhealthy, unhealthy
    return True


smoke.wait("all operational alert rules successfully evaluated", evaluated_alerts)
dashboard = smoke.request(smoke.GRAFANA + "/api/dashboards/uid/nephos-operations", basic=auth)
assert dashboard["dashboard"]["title"] == "Nephos operations"
trace_id = uuid.uuid4().hex
with smoke.AdminSession() as admin:
    admin.request(headers={"traceparent": f"00-{trace_id}-{secrets.token_hex(8)}-01"})
smoke.wait("administration request metrics centrally stored", lambda: query("nephos_admin_requests_total > 0"))
datasources = smoke.GRAFANA + "/api/datasources/proxy/uid/"
logs = urllib.parse.urlencode(
    {"query": '{service_name="nephos-admin-console"} | trace_id = "' + trace_id + '"', "limit": 10}
)
smoke.wait(
    "administration logs centrally stored and correlated",
    lambda: smoke.request(datasources + "loki/loki/api/v1/query_range?" + logs, basic=auth)["data"]["result"],
)


def complete_trace():
    value = smoke.request(datasources + "tempo/api/traces/" + trace_id, basic=auth)
    encoded = json.dumps(value)
    return value if "administration dependency" in encoded and "nephos-library-admin" in encoded else None


trace = smoke.wait("administration dependency trace centrally stored", complete_trace)
serialized = json.dumps(trace)
assert smoke.ENV["KEYCLOAK_ADMIN_PASSWORD"] not in serialized and smoke.ENV["ADMIN_SERVICE_KEY"] not in serialized
for user, allowed_read, allowed_write in (
    ("storage-publisher", "^$", r"^amq\.default$"),
    ("library-projector", r"^nephos\.assets\.ready$", "^$"),
):
    result = subprocess.run(
        ["docker", "compose", "exec", "-T", "rabbitmq", "rabbitmqctl", "list_user_permissions", user, "--quiet"],
        cwd=smoke.ROOT,
        check=True,
        capture_output=True,
        text=True,
    )
    assert f"/\t^$\t{allowed_write}\t{allowed_read}" in result.stdout, "Unexpected worker broker permissions"
for path in ("/admin/", "/realms/master/", "/metrics", "/internal/administration/users"):
    smoke.request(smoke.API + path, expected=404)
print(
    "PASS: persisted operational gauges, evaluated alert rules, provisioned dashboard, restricted broker identities and private gateway routes"
)
