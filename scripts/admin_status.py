"""Bounded private service probes and fixed broker telemetry queries."""

from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import os
import logging
import time

import requests

logger = logging.getLogger("nephos.administration.status")


def now():
    return datetime.now(timezone.utc).isoformat()


def probe(item):
    name, description, url = item
    if url is None:
        return {"name": name, "description": description, "state": "Not installed", "checkedAt": now()}
    try:
        response = requests.get(url, timeout=(2, 3), allow_redirects=False)
        state = "Ready" if response.status_code == 200 else "Not ready"
    except requests.Timeout:
        logger.warning("Administration health probe timed out", extra={"service": name})
        state = "Timed out"
    except (requests.RequestException, ValueError):
        logger.warning("Administration health probe failed", extra={"service": name})
        state = "Unavailable"
    return {"name": name, "description": description, "state": state, "checkedAt": now()}


def services():
    faces = os.environ.get("ADMIN_FACES_URL")
    items = [
        (
            "Authentication",
            "Keycloak: media realm configuration.",
            os.environ["IDENTITY_URL"].rstrip("/") + "/realms/nephos/.well-known/openid-configuration",
        ),
        (
            "Libraries",
            "Library API: service and database readiness.",
            os.environ.get("ADMIN_LIBRARY_HEALTH_URL", "http://library-api:8080/health/ready"),
        ),
        (
            "Storage",
            "Storage API: database readiness and media volume write check.",
            os.environ.get("ADMIN_STORAGE_HEALTH_URL", "http://storage-api:8080/health/ready"),
        ),
        (
            "Telemetry",
            "Prometheus: metrics store readiness.",
            os.environ.get("ADMIN_PROMETHEUS_URL", "http://prometheus:9090").rstrip("/") + "/-/ready",
        ),
        (
            "Face recognition",
            "Faces API: database readiness.",
            faces.rstrip("/") + "/health/ready" if faces else None,
        ),
    ]
    with ThreadPoolExecutor(max_workers=len(items)) as executor:
        return list(executor.map(probe, items))


def broker_metrics():
    base = os.environ.get("ADMIN_PROMETHEUS_URL", "http://prometheus:9090").rstrip("/")
    definitions = [
        ("Broker: awaiting delivery", "rabbitmq_queue_messages_ready"),
        ("Broker: in progress", "rabbitmq_queue_messages_unacked"),
    ]

    def read(definition):
        label, metric = definition
        result = {"label": label, "unit": "Messages", "value": None, "state": "No data", "observedAt": None}
        try:
            response = requests.get(
                base + "/api/v1/query",
                params={"query": "sum(" + metric + ")"},
                timeout=(2, 3),
                allow_redirects=False,
            )
            response.raise_for_status()
            payload = response.json()
            if payload.get("status") != "success":
                result["state"] = "Collection error"
                return result
            samples = payload["data"]["result"]
            if not samples:
                return result
            response = requests.get(
                base + "/api/v1/query",
                params={"query": "min(timestamp(" + metric + "))"},
                timeout=(2, 3),
                allow_redirects=False,
            )
            response.raise_for_status()
            timestamps = response.json()
            if timestamps.get("status") != "success" or not timestamps["data"]["result"]:
                result["state"] = "Observation time unavailable"
                return result
            timestamp = float(timestamps["data"]["result"][0]["value"][1])
            value = samples[0]["value"][1]
            if time.time() - float(timestamp) > 60:
                result["state"] = "Data is stale"
                return result
            result.update(
                value=int(float(value)), observedAt=datetime.fromtimestamp(float(timestamp), timezone.utc).isoformat()
            )
        except requests.Timeout:
            logger.warning("Administration metric query timed out", extra={"metric": metric})
            result["state"] = "Timed out"
        except (requests.RequestException, KeyError, ValueError, OverflowError, TypeError):
            logger.warning("Administration metric query failed", extra={"metric": metric})
            result["state"] = "Collection error"
        return result

    with ThreadPoolExecutor(max_workers=len(definitions)) as executor:
        return list(executor.map(read, definitions))
