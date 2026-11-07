# Nephos designs in Penpot

The editable source is **Nephos Admin — Design System & UX** in the
**Nephos Admin** project. On this Mac:

- [Foundations](http://localhost:9001/#/workspace?team-id=2a4e1ac4-5a73-80ac-8008-e8cce365ad2f&file-id=2a4e1ac4-5a73-80ac-8008-e8cfe4eedfef&page-id=a7237ac9-d665-41b8-a500-6294db96931c)
- [Reusable components](http://localhost:9001/#/workspace?team-id=2a4e1ac4-5a73-80ac-8008-e8cce365ad2f&file-id=2a4e1ac4-5a73-80ac-8008-e8cfe4eedfef&page-id=5f1a2c5b-c560-492f-860c-a6e250be0720)
- [Admin user creation, QR, and connected devices](http://localhost:9001/#/workspace?team-id=2a4e1ac4-5a73-80ac-8008-e8cce365ad2f&file-id=2a4e1ac4-5a73-80ac-8008-e8cfe4eedfef&page-id=7b06007a-4a5b-4f2b-be6e-58af0c4f965d)
- [Mobile QR flow, light and dark](http://localhost:9001/#/workspace?team-id=2a4e1ac4-5a73-80ac-8008-e8cce365ad2f&file-id=2a4e1ac4-5a73-80ac-8008-e8cfe4eedfef&page-id=e827db53-5187-4b5b-9a4a-14097bc19764)

The file is published as a library to the local Penpot team. Connect it from
another file through **Assets → Manage library**. Its nine reusable assets
are Button, Text field, Checkbox, Alert, Navigation item, QR icon, QR
placeholder, Icon button, and Device row. Button variants use Type, State, Platform, and
Theme; action text such as “Cancel QR code” is an instance override, not a
separate component.

Native token sets separate primitives, semantic roles, and component roles.
The `Nephos Preview / Light` and `Dark` themes switch the foundations preview;
the mobile flows show both themes together. In Penpot 2.18.6, disabled opacity
is mirrored from `opacity.disabled` rather than dynamically bound: update the
disabled components if that token changes.

The admin canvas includes creation, QR enrollment, connected devices, and device
revocation with confirmation, pending, success, and failure/retry states.
The arrows document the flows, and View mode has clickable prototype paths.
Revocation dialogs use a **selected-session template**: the target name and
session details must come from the selected device, not a hardcoded example.
The success screen removes that selected session while retaining other sessions.
Closing a pending dialog does not cancel the request. Media is never deleted.

In View mode, click the QR placeholder to simulate enrollment and the pending
revocation message to simulate server confirmation. Open the revocation-error
board to explore the alternate server outcome. These are prototype simulations,
not implemented server behavior. Camera scanning, photo selection, real sign-in,
and the native photo picker are likewise not implemented in the prototype.
All designs remain **drafts**, not approved designs.

## Action placement

The Components canvas documents the shared action rules, based on
[IBM Carbon's modal guidelines](https://carbondesignsystem.com/components/modal/usage/):

- Paired actions: secondary/cancel on the left, primary/destructive commit on the right.
- A single modal-footer action is centered, regardless of intent. This is the
  user's explicit Nephos convention, **not** Carbon's single-action alignment.
- Text buttons reuse Button variants: 180 x 44 standard, 224 x 44 for long labels,
  16px paired gap, and 24px modal content/footer insets. Sizing uses native
  primitive-to-semantic-to-component token aliases.
- Card actions align to the content edge; empty-state actions align with the
  centered message; device-row actions stay at the trailing edge.
- Keep destructive confirmation explicit, prevent duplicate submissions while
  pending, and show actionable failure feedback. Implementation must trap focus,
  initially focus Cancel for destructive confirmation, and restore trigger focus.

Nephos deliberately retains inset, rounded controls rather than Carbon's
full-bleed modal footer. Do not mix in a competing primary-left ordering.

All twelve addressed comment threads are marked resolved on the live Penpot file;
their history remains there. Comments are not included in `.penpot` exports
and require a live-server backup to preserve. The two mobile-feedback threads
remain on the admin canvas because Penpot does not move comments between pages.
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
may change, and the imported file may need to be published as a library again.
The two other exports preserve earlier drafts before scope reduction. Named
Penpot snapshots preserve the previous and current live versions.
An export is not a full server backup: back up PostgreSQL consistently with
the matching assets separately, while writes are stopped.

Only explicit visual approval moves a design out of draft status. Save a
named Penpot version and export it alongside its approval record before
changing an approved design; do not overwrite approved work with a new variant.
