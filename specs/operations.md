# Deployment and backups

Use the root [README](../README.md) for initial setup and launch.
All commands below run from the repository root. Keep administration on loopback
or an explicitly protected private endpoint; do not publish its ports.

## HTTPS

The iOS app requires the canonical HTTPS media origin and a trusted certificate.
Plain HTTP local Compose is for backend development, not phone enrollment.
Configure DNS to reach the host, and make the canonical hostname reachable from
both clients and containers.

Set `PUBLIC_HOST` to your real DNS hostname in `.env`, then launch:

```sh
docker compose -f compose.yaml -f compose.tls.yaml up -d --build
```

The TLS overlay sets the public Keycloak hostname and `NEPHOS_PUBLIC_ORIGIN`.
The master realm keeps its private frontend origin, normally
`http://localhost:18081`; `PRIVATE_KEYCLOAK_URL` configures the separate provider
administration hostname. Use [private administration](administration.md) for
origin/bootstrap configuration.

Caddy exposes the versioned media APIs, the public Nephos realm's permitted
identity routes and provider resources. Internal APIs, operator routes,
PostgreSQL, RabbitMQ and monitoring remain private.
No certificate verification bypass is supported.

For existing installations, run `python3.12 scripts/upgrade-dev-env.py` before
rebuilding. Preserve all active Compose/env overlays during upgrades. Environment
edits alone do not rotate database, broker or identity credentials.

## Optional services

- **Faces:** follow [face analysis](face-analysis.md) for targeted installation
  and migration commands. HTTPS overlay order is `compose.yaml`,
  `compose.faces.yaml`, `compose.tls.yaml`, `compose.faces.tls.yaml`.
- **Monitoring:** `COMPOSE_PROFILES=observability` enables the Collector,
  Prometheus, Loki, Tempo and Grafana. Set `COMPOSE_PROFILES=""` to omit them.
- **LAN announcement:** see [local discovery](local-discovery.md). The current
  iOS app still obtains its server origin from QR enrollment.

## Local endpoints

| Address | Purpose |
|---|---|
| `http://localhost:18080` | Media API |
| `http://localhost:18082` | Nephos administrator console |
| `http://localhost:18081/admin/` | Keycloak provider administration |
| `http://localhost:18083` | Development Mailpit inbox |
| `http://localhost:13000` | Grafana, when monitoring is enabled |

Use username `admin` and `KEYCLOAK_ADMIN_PASSWORD` from `.env` for the private
administration consoles, and `GRAFANA_PASSWORD` for Grafana. Never publish these
credentials. Database, broker and OTLP ports are not host-published.

## Monitoring

The **Nephos / Nephos operations** dashboard shows heartbeats, volume headroom,
uploads, queues, alerts and trace-linked logs. Missing/stale observations are not
proof of zero work or good health. External email/paging delivery is not configured.

Telemetry queues/retries are bounded and do not authorize domain operations.
Prometheus retains seven days/512 MB, Loki seven days and Tempo one day.
The administration operation journal, not telemetry, records durable commands.

Internal traffic trusts the host's private Docker networks; this is not
multi-host mTLS or hostile-container isolation.

## Backups and restore

Keep independent encrypted backups. RAID and a second reference to the same
mounted blob do not protect against host/storage failure.

```sh
python3.12 scripts/backup.py create --online /private/backup/nephos-snapshot
python3.12 scripts/backup.py verify /private/backup/nephos-snapshot
python3.12 scripts/backup.py restore /private/backup/nephos-snapshot --project nephos-restored
```

Online backups keep normal writers running, pause cleanup, dump database state
and archive original blobs rather than rebuildable previews/staging. Cold backups
omit `--online` and pause services to archive PostgreSQL, RabbitMQ and media volumes.
Both include optional Faces data and `.env.faces` when active.
Face labels and corrections cannot be reconstructed from originals.

Creation refuses an existing destination; restore refuses existing target volumes.
Follow the helper's printed Compose command using matching code/images and stop
conflicting host ports before launching a restored deployment. Raw-volume restore
requires compatible database/broker versions and architecture.
Set `NEPHOS_ENV_FILE` when using a non-default environment file.

Archives contain plaintext media and credentials. Permissions and checksums are
not encryption or authenticity protection. Do not publish archives or run restore
tests against live volumes.

Before accepting traffic after restore, invalidate restored QR invitation/receipt
state, rotate the QR delivery generation/key and follow the session recovery
instructions in [administration](administration.md) and
[QR enrollment](qr-enrollment.md#configuration-and-migration). Do not restore
operator sessions.

## Stop

```sh
docker compose down
```

This stops the selected project and preserves its named data volumes.
Include the same overlays used at launch when stopping an optional stack.
