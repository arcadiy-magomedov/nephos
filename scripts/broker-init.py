#!/usr/bin/env python3
"""Idempotently provision queues and separate non-administrative worker identities."""

import base64
import json
import os
import time
import urllib.error
import urllib.request

authorization = "Basic " + base64.b64encode(("nephos:" + os.environ["RABBITMQ_PASSWORD"]).encode()).decode()

for attempt in range(30):
    try:
        with urllib.request.urlopen(
            urllib.request.Request("http://rabbitmq:15672/api/overview", headers={"Authorization": authorization}),
            timeout=3,
        ) as response:
            response.read()
        break
    except urllib.error.HTTPError:
        raise
    except (urllib.error.URLError, TimeoutError):
        if attempt == 29:
            raise RuntimeError("Broker management endpoint unavailable; provisioning did not run.") from None
        time.sleep(2)


def put(path, value):
    request = urllib.request.Request(
        "http://rabbitmq:15672/api/" + path,
        data=json.dumps(value).encode(),
        method="PUT",
        headers={"Authorization": authorization, "Content-Type": "application/json"},
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        response.read()


put("queues/%2F/nephos.assets.dead", {"durable": True, "auto_delete": False, "arguments": {}})
put(
    "queues/%2F/nephos.assets.ready",
    {
        "durable": True,
        "auto_delete": False,
        "arguments": {"x-dead-letter-exchange": "", "x-dead-letter-routing-key": "nephos.assets.dead"},
    },
)
for user, variable, read, write in (
    ("storage-publisher", "BROKER_PUBLISHER_PASSWORD", "^$", r"^amq\.default$"),
    ("library-projector", "BROKER_PROJECTOR_PASSWORD", r"^nephos\.assets\.ready$", "^$"),
):
    put("users/" + user, {"password": os.environ[variable], "tags": []})
    put("permissions/%2F/" + user, {"configure": "^$", "read": read, "write": write})
print("Durable queues and restricted publisher/projector identities provisioned.")
