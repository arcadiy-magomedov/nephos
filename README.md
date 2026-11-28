# Nephos

Self-hosted photo and video backup with a native iOS app, resumable uploads,
Live Photo support, private sharing and optional local face recognition.
Accounts are created by an administrator; there is no public registration.
Books, cinema libraries and semantic search are planned, not yet implemented.

[Specifications](specs/README.md) include the
[system and UX diagrams](specs/system-and-flows.md).
Use requires permission under the [license](LICENSE).

## Requirements

- Docker with Docker Compose v2.
- Python 3.12 or newer.
- Several GB of RAM and enough disk space for your media.
- For iOS: macOS with Xcode, an iOS 17+ device, and a trusted HTTPS server address.
- For local backend development: the .NET SDK pinned in `global.json`.

## Setup

From the repository root:

```sh
python3.12 scripts/dev-env.py
```

This creates local credentials in `.env`. For an existing installation, run
`python3.12 scripts/upgrade-dev-env.py` instead; existing credentials are kept.
Set `COMPOSE_PROFILES=""` in `.env` to omit the optional monitoring containers.

Keep an independent backup of your media and credentials. RAID is not a backup.

## Launch

```sh
docker compose up -d --build
```

Open the [admin console](http://localhost:18082) and sign in as `admin` using
`KEYCLOAK_ADMIN_PASSWORD` from `.env`. The local API is at
`http://localhost:18080`. Administration stays private.

For phone access, configure your DNS and trusted HTTPS endpoint using the
[deployment instructions](specs/operations.md#https).
Then create a user in the admin console and issue a QR code.

To launch the iOS app:

```sh
python3.12 ios/generate_project.py
open ios/Nephos.xcodeproj
```

Select your signing team and device in Xcode, run the app, and scan the QR code.
Enable automatic backup in the app's settings.

Stop the stack without deleting its data:

```sh
docker compose down
```
