# Nephos designs in Penpot

The local editable source is the **Nephos Admin — Design System & UX** file
in the **Nephos Admin** project. Its first page contains the complete user
creation and QR login flow on one canvas; the second contains only components
used by that scenario. Materials are drafts, not approved designs.

On this Mac, open
<http://localhost:9001/#/workspace?team-id=2a4e1ac4-5a73-80ac-8008-e8cce365ad2f&file-id=2a4e1ac4-5a73-80ac-8008-e8cfe4eedfef&page-id=7b06007a-4a5b-4f2b-be6e-58af0c4f965d>.
Credentials are in the ignored `.credentials.json` file.

## Run

```sh
cd design/penpot
python3 bootstrap.py
docker compose --env-file .env -f compose.yaml up -d
```

The services bind to loopback only. Penpot images are pinned to the deployed
2.18.6 digests; `.data/`, `.env` and `.credentials.json` are local and ignored.
`bootstrap.py` creates local secrets, but does not create the Penpot user:
on a fresh installation create a profile with Penpot's management CLI before
signing in. The existing installation already has its profile.

## Versions and recovery

`exports/nephos-admin-user-qr.penpot` is a portable editable draft export.
Import it from the Penpot dashboard on a new installation; file and page IDs
may change. The two other exports preserve earlier drafts before scope
reduction. A named Penpot snapshot also preserves the previous live version.
An export is not a full server backup: back up PostgreSQL consistently with
the matching assets separately, while writes are stopped.

Only explicit visual approval moves a design out of draft status. Save a
named Penpot version and export it alongside its approval record before
changing an approved design; do not overwrite approved work with a new variant.
