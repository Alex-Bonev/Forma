# RoomVibe

Scan a room with LiDAR, scan a real object, drop the object into the room and see if it fits.
Hackathon project. Native iOS (SwiftUI + RoomPlan + Object Capture + RealityKit), thin FastAPI backend for AI calls.

## Requirements

- Mac with Xcode 26+ (project targets iOS 18).
- iPhone **Pro** with LiDAR (12 Pro or later) for scanning. Any iPhone or the Simulator works for the Designer using demo data.
- Apple ID signed into Xcode (free account is fine; on-device installs expire after 7 days).

## First-time setup (each teammate)

```sh
git clone https://github.com/Alex-Bonev/RoomVibe.git
cd RoomVibe
cp Config/Local.xcconfig.example Config/Local.xcconfig
```

Edit `Config/Local.xcconfig`:

- `DEVELOPMENT_TEAM` — your team ID. Find it in Xcode > Settings > Accounts, or Xcode will show it under
  Signing & Capabilities once you pick your team.
- `RV_BUNDLE_PREFIX` — something unique to you, e.g. `com.yourname`. Free accounts cannot share bundle IDs.

`Local.xcconfig` is gitignored, so signing never causes merge conflicts.

Then `open RoomVibe.xcodeproj`.

## Run on your iPhone

1. Plug the iPhone into the Mac with a cable and tap **Trust** on the phone.
2. On the phone: Settings > Privacy & Security > **Developer Mode** > on. The phone restarts; confirm.
3. In Xcode, pick your iPhone in the device menu at the top of the window, then press **Run** (⌘R).
4. First run only: on the phone go to Settings > General > **VPN & Device Management**, tap your Apple ID
   under Developer App, then **Trust**. Run again from Xcode.
5. In the app: menu (•••) > **Load Demo Data**, open "Demo Living Room", tap **+ Demo Chair**, drag the chair around.
   On a LiDAR iPhone, **Scan Room** and **Scan Object** are enabled.

Tip: add `-demo` under Product > Scheme > Edit Scheme > Run > Arguments to jump straight into the demo room.

From the command line instead (phone connected, unlocked):

```sh
xcodebuild -project RoomVibe.xcodeproj -scheme RoomVibe -destination 'platform=iOS,name=<Your iPhone name>' \
  -allowProvisioningUpdates -derivedDataPath build build
xcrun devicectl device install app --device <Your iPhone name> build/Build/Products/Debug-iphoneos/RoomVibe.app
```

## Project layout

```
RoomVibe/
  App/                     app entry
  Core/                    Models (Project, ScannedObject, Placement, RoomModel), ProjectStore, Capabilities
  Features/Home/           room list + object library
  Features/RoomScan/       RoomPlan capture -> RoomModel + captured.json + room.usdz
  Features/ObjectScan/     Object Capture -> PhotogrammetrySession -> model.usdz
  Features/Designer/       RealityView dollhouse, RoomBuilder, drag/rotate/delete placements
  Resources/DemoData/      sample_room.json (hand-made room for no-LiDAR devices)
backend/                   FastAPI: /health, /render, /vibe/analyze, /vibe/products (MOCK=1 by default)
project.yml                XcodeGen spec (optional, see below)
```

The Xcode project uses folder-synced groups: drop a new `.swift` file anywhere under `RoomVibe/` and Xcode picks it
up with no `.pbxproj` change. Only regenerate with `xcodegen generate` if you change `project.yml`.

Storage: `Application Support/library.json` is the index; room and object files live in
`Application Support/Projects/<id>/` and `Application Support/Objects/<id>/`.

## Backend

```sh
cd backend
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt pytest
.venv/bin/pytest -q                      # self-check
MOCK=1 .venv/bin/fastapi dev main.py     # local server on :8000
```

Deploy: `vercel` from `backend/` (preview), `vercel --prod` (live). Set env vars from `.env.example`.
Vercel caps request and response bodies at 4.5 MB: send JPEG snapshots, never USDZ files.
The AI provider is not picked yet; non-mock endpoints return 501 until one is wired in.

## Work split

See `docs/PLAN.md` (scope, ownership, 48h timeline) and the per-person handoff prompts in `docs/`:
A = scanning (`handoff-A-scanning.md`), B = Designer/visuals/AR (`handoff-B-designer.md`),
C = backend/AI/render/vibe (`handoff-C-backend-ai.md`).

## Status / known gaps

- Scanning only runs on a LiDAR device; verify on the demo phone early.
- Custom orbit camera: drag empty space to orbit, drag an object to move it, pinch to zoom, twist to rotate the selection.
- Placements clamp to the room's bounding rectangle, not the exact wall outline.
- Not built yet: app-side API client, photoreal render, vibe mode, AR view, generic furniture USDZ swap.
