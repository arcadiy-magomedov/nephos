# Specifications

Detailed contracts, deployment guides and design documentation live here.
Commands are run from the repository root unless a guide says otherwise.
Files in `deploy/`, `ios/`, `face-inference/` and `design/` remain implementation
or design assets, not alternative specification locations.

## System and product

| Document | Contents |
|---|---|
| [System and UX diagrams](system-and-flows.md) | Current services and major user journeys |
| [Media platform](000-media-platform.md) | Product requirements and engineering standard |
| [System architecture](001-system-architecture.md) | Target architecture and service boundaries |
| [Threat model](002-threat-model.md) | Security boundaries and risks |
| [Mobile client](003-mobile-client.md) | Mobile requirements and target behavior |
| [Execution plan](004-mvp-execution-plan.md) | Roadmap and implementation stages |
| [Implementation and media API](media-api.md) | Current scope, uploads, gallery, sharing and retention |
| [API compatibility](005-api-compatibility.md) | Public and private versioning contracts |

## Features and operations

| Document | Contents |
|---|---|
| [iOS client](ios-client.md) | Current app, background uploads and session behavior |
| [Administrator console](admin-console.md) | Screens, provisioning and device management |
| [Administration API](administration-api.md) | Durable administrative commands |
| [Private administration](administration.md) | Operator authentication, deployment and recovery |
| [QR enrollment](qr-enrollment.md) | Keycloak and device-bound persistent sessions |
| [Face analysis](face-analysis.md) | Existing inference, clustering and correction contracts |
| [Cleanup](cleanup.md) | Deleted-resource retention and garbage collection |
| [Deployment and backups](operations.md) | HTTPS, optional services, monitoring and restore |
| [Development and validation](development.md) | Lint presets, tests and release checks |
| [Native QR CI](native-qr-ci.md) | Isolated real-service enrollment qualification |
| [Local discovery](local-discovery.md) | Optional server announcement tooling |
| [Design system](design-system.md) | Penpot components, flows, approvals and recovery |

Target specifications and design drafts are not evidence that a feature has
shipped. The implementation inventory and diagrams distinguish current behavior
from planned work.
