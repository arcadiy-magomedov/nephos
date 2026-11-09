# Nephos designs in Penpot

**Canvas separation rule:** Keep every mobile app screen and flow together on
the dedicated mobile canvas. Keep every admin portal screen and UX flow on the
separate admin canvas. Never mix the two.

The editable source is **Nephos Admin — Design System & UX** in the
**Nephos Admin** project. On this Mac:

- [Foundations](http://localhost:9001/#/workspace?team-id=2a4e1ac4-5a73-80ac-8008-e8cce365ad2f&file-id=2a4e1ac4-5a73-80ac-8008-e8cfe4eedfef&page-id=a7237ac9-d665-41b8-a500-6294db96931c)
- [Reusable components](http://localhost:9001/#/workspace?team-id=2a4e1ac4-5a73-80ac-8008-e8cce365ad2f&file-id=2a4e1ac4-5a73-80ac-8008-e8cfe4eedfef&page-id=5f1a2c5b-c560-492f-860c-a6e250be0720)
- [User-facing foundations](http://localhost:9001/#/workspace?team-id=2a4e1ac4-5a73-80ac-8008-e8cce365ad2f&file-id=2a4e1ac4-5a73-80ac-8008-e8cfe4eedfef&page-id=c3b4bb7d-05de-803c-8008-e93747c75115)
- [User-facing components](http://localhost:9001/#/workspace?team-id=2a4e1ac4-5a73-80ac-8008-e8cce365ad2f&file-id=2a4e1ac4-5a73-80ac-8008-e8cfe4eedfef&page-id=c3b4bb7d-05de-803c-8008-e937481380d4)
- [Admin portal screens and flows](http://localhost:9001/#/workspace?team-id=2a4e1ac4-5a73-80ac-8008-e8cce365ad2f&file-id=2a4e1ac4-5a73-80ac-8008-e8cfe4eedfef&page-id=7b06007a-4a5b-4f2b-be6e-58af0c4f965d)
- [Mobile app screens and flows](http://localhost:9001/#/workspace?team-id=2a4e1ac4-5a73-80ac-8008-e8cce365ad2f&file-id=2a4e1ac4-5a73-80ac-8008-e8cfe4eedfef&page-id=c3b4bb7d-05de-803c-8008-e93748606044)

The file is published as a library to the local Penpot team. Connect it from
another file through **Assets → Manage library**. The admin assets are Button,
Text field, Checkbox, Alert, Navigation item, QR icon, QR placeholder, Icon
button, and Device row. The user-facing library adds Filter chip, User text
field, User tab item, Media tile, Status badge, and User icon button. The
shared Button set uses Type, State, Platform, and Theme; action text such as
“Cancel QR code” is an instance override, not a separate component.

Native token sets separate primitives, semantic roles, and component roles.
The user-facing direction uses neutral white/charcoal surfaces and a restrained
blue action color; red and amber are reserved for semantic states. The
foundations page is the source of truth for the complete palette:

| Role | Light | Dark |
| --- | --- | --- |
| Background | `#FFFFFF` | `#111318` |
| Surface | `#F4F5F8` | `#1C2028` |
| Primary text | `#191D27` | `#F3F5F8` |
| Secondary text | `#525D6D` | `#B4BBC8` |
| Action | `#3157C8` | `#A9BAFA` |
| On action | `#FFFFFF` | `#191D27` |

Component variants show both appearances together. Mobile screen frames bind
colors to mode-neutral `semantic.user.*` and `component.user.*` aliases, so each
screen exists once and follows the Light/Dark token sets. Source-indicator colors
and the upload overlay remain invariant for readability over media.
Mobile text uses direct semantic color aliases. Materialize text-range fill
overrides before binding tokens so inherited colors do not return after reload.

**Do not toggle the
`Nephos Preview / Light` or `Dark` themes in the shared file:** Penpot 2.18.6 can reflow existing admin
text even after the original theme is restored. Test theme switching only in an
isolated copy. Use the private
[mobile theme preview](http://localhost:9001/#/workspace?team-id=2a4e1ac4-5a73-80ac-8008-e8cce365ad2f&file-id=fa0c6273-dbed-81e9-8008-ea6e916c3b63&page-id=c3b4bb7d-05de-803c-8008-e93748606044)
and choose **Tokens → Themes → Nephos Preview → Light / Dark**. It contains
the sign-in flow and gallery without a copied admin-screen canvas; it is not
the canonical source. Disabled opacity is mirrored from `opacity.disabled` rather than
dynamically bound: update the disabled components if that token changes.

The mobile canvas contains one theme-aware QR sign-in flow above the separately
marked gallery section. The path runs Sign in → Scan → Signing in; invalid or expired codes
branch from Scan to QR error, and Retry returns to Scan. The error states have
separate prototype starts because the prototype does not simulate conditional
scan outcomes. Existing static previews predate the theme-aware consolidation:
[entire mobile canvas](previews/mobile-app-canvas.png)
and [mobile QR flow](previews/mobile-qr-flow.png).

**Approved baseline:** The original light/dark mobile sign-in flow, including its scan and error
states, was approved on 2026-11-08. Its named Penpot snapshot and
[approved export](exports/nephos-mobile-sign-in-approved.penpot) preserve the
baseline. The export contains the whole file, but approval covers only sign-in.
The current theme-aware consolidation is a draft for review; the original
interaction paths and both palettes are preserved.

The user-app boards preserve the gallery, filters, source and sharing
indicators, selection, and navigation as visual examples. They use public-domain
sample photos credited on the board. The new palette and components are **draft**
designs and have not yet been adopted by the shipped iOS app. Portable previews:
[foundations](previews/user-foundations.png), [components](previews/user-components.png),
and [gallery](previews/user-app-previews.png).

The mobile gallery uses twelve complete, linked **MediaThumbnail** instances.
The component on **04 · User components** contains the image, source/shared
indicators, upload overlay, and video duration. Select the inner `thumbnail-*`
instance, not its outer `gallery-cell-*` layout board, to change **Kind**
(`Photo` / `Video`) and the boolean variant controls **hasLocalMedia**,
**isUploaded**, **isShared**, and **isUploading**. These select predefined
visual variants, not runtime conditional logic.

The twelve variants cover Photo/Video for local-only, uploaded-only, local and
uploaded, shared remote, shared local, and uploading states. Shared states show
only the shared icon. Override the nested `media / Media slot` image fill and
`duration / Label` text per instance; these overrides survive variant changes.
Duration is visible only for Video and retains the same 4px edge insets as the
source indicators. Uploading retains the editable, static angular-gradient
sample; it is not an animated progress implementation. The main gallery and
isolated mobile theme preview use the same component structure.

The mobile viewer draft adds photo, video-playback, and expanded **More** states.
Tap the zinnia photo or the video thumbnail in Today to open the corresponding
viewer; Back returns to the gallery. Media fits without cropping. Capture
date/time appear only in the header instead of storage-status copy; the
illustrated metadata is sample content, not EXIF extracted from the bundled
media. Location is not displayed in the current draft.

The viewer offers **Share** and **More**, without Favorite or Info.
More opens a small context menu anchored beneath the **…** button, containing
**Download original** and destructive **Delete**, without background dimming.
Tapping outside dismisses it and preserves the current photo/video context.
Albums are absent from navigation and the menu.
`MediaActionsMenu` has `isShared=false/true` variants; the shared variant has
**Download original** only and no Delete action. `MediaDeletionDialog` has
`isUploaded=true/false` variants. Uploaded media offers **Delete from device**,
**Delete everywhere**, and **Cancel**; not-uploaded media offers **Delete from
device** and **Cancel**. The first, second, third, and sixth Today thumbnails
demonstrate not-uploaded, uploaded, shared, and uploaded-video flows.
Device-only deletion preserves an existing backup; shared media cannot be
deleted. Destructive operations and downstream downloads are not simulated.
Video uses a static
poster and playback-control illustration, not an embedded playback engine.

Current portable previews:
[gallery](previews/mobile-gallery.png),
[photo viewer](previews/mobile-photo-viewer.png),
[video viewer](previews/mobile-video-viewer.png),
[anchored menu](previews/mobile-media-menu.png),
[menu variants](previews/mobile-media-menu-variants.png), and
[deletion confirmations](previews/mobile-delete-confirmations.png).
These show the current Dark appearance; the new viewer/dialog states have not
been visually rechecked in Light. The separate mobile theme preview currently
contains sign-in and gallery only, not the new viewer and deletion flows.

The separate admin canvas includes user creation, QR enrollment,
connected devices, and device revocation with confirmation, pending, success,
and failure/retry states. The arrows document the flows, and View mode has
clickable prototype paths. See the [admin flow preview](previews/admin-flow.png).
Revocation dialogs use a **selected-session template**: the target name and
session details must come from the selected device, not a hardcoded example.
The success screen removes that selected session while retaining other sessions.
Closing a pending dialog does not cancel the request. Media is never deleted.

In View mode, click the QR placeholder to simulate enrollment and the pending
revocation message to simulate server confirmation. Open the revocation-error
board to explore the alternate server outcome. These are prototype simulations,
not implemented server behavior. Camera scanning, photo selection, real sign-in,
and the native photo picker are likewise not implemented in the prototype.
The gallery, shared user-facing system, and admin designs remain **drafts**.

## Action placement

The Components canvas documents the shared action rules, based on
[IBM Carbon's modal guidelines](https://carbondesignsystem.com/components/modal/usage/):

- Paired actions: secondary/cancel on the left, primary/destructive commit on the right.
- A single modal-footer action is centered, regardless of intent. This is the
  user's explicit Nephos convention, **not** Carbon's single-action alignment.
- Admin modal text buttons reuse Button variants: 180 x 44 standard, 224 x 44 for long labels,
  16px paired gap, and 24px modal content/footer insets. Sizing uses native
  primitive-to-semantic-to-component token aliases.
- Card actions align to the content edge; empty-state actions align with the
  centered message; device-row actions stay at the trailing edge.
- Keep destructive confirmation explicit, prevent duplicate submissions while
  pending, and show actionable failure feedback. Implementation must trap focus,
  initially focus Cancel for destructive confirmation, and restore trigger focus.

Nephos deliberately retains inset, rounded controls rather than Carbon's
full-bleed modal footer. Do not mix in a competing primary-left ordering.

Comment threads and their resolution history remain on the live Penpot file.
Comments are not included in `.penpot` exports and require a
live-server backup to preserve. Historical feedback anchors remain on their
original page, even when they concern a moved mobile screen. Credentials are in
the ignored `.credentials.json` file.

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

`exports/nephos-user-system.penpot` is the latest portable editable draft
export of the shared file, including the user-facing library.
The 2026-11-09 delivery captures live revision 261. It was restored in an
isolated project: all six pages, 151 component records, variant properties,
token definitions, theme selections, geometry, and prototype destinations
matched the source. Saved View-mode checks covered uploaded photo/video,
not-uploaded media, shared media without Delete, and confirmation cancellation.
`exports/nephos-admin-user-qr.penpot` preserves the earlier admin/QR draft.
Import an export from the Penpot dashboard on a new installation; file and page IDs
may change, and the imported file may need to be published as a library again.
The two other exports preserve earlier drafts before scope reduction. Named
Penpot snapshots preserve the previous and current live versions.
An export is not a full server backup: back up PostgreSQL consistently with
the matching assets separately, while writes are stopped.

Only explicit visual approval moves a design out of draft status. Save a
named Penpot version and export it alongside its approval record before
changing an approved design; do not overwrite approved work with a new variant.
