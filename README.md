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
backend/                   FastAPI: /health, /render, /vibe/* (MOCK=1 by default), run locally with scripts/run_local.sh
supabase/migrations/       cloud library schema (Supabase Postgres + Storage)
project.yml                XcodeGen spec (optional, see below)
```

The Xcode project uses folder-synced groups: drop a new `.swift` file anywhere under `RoomVibe/` and Xcode picks it
up with no `.pbxproj` change. Only regenerate with `xcodegen generate` if you change `project.yml`.

Storage: `Application Support/library.json` is the index; room and object files live in
`Application Support/Projects/<id>/` and `Application Support/Objects/<id>/`. With a cloud config the library is
also mirrored to Supabase (see "Cloud library" below); the local copy stays the working copy.

## Cloud library (Supabase)

`Core/Cloud/CloudSync.swift` mirrors the library to a Supabase project; `Core/Cloud/CloudClient.swift` is a thin
REST client for Auth, PostgREST and Storage (no SDK dependency). Without a cloud config the app works as before,
on this device only.

What goes where:

| Local | Supabase |
| --- | --- |
| `library.json` entry for a room (`Project`: name, placements, finishes, hidden objects) | `projects.doc` (jsonb) |
| `Projects/<id>/room.json` (`RoomModel`) | `projects.room` (jsonb) |
| `library.json` entry for an object (`ScannedObject`) | `scanned_objects.doc` (jsonb) |
| other files in `Projects/<id>/` (`thumb.jpg`, `captured.json`, `room.usdz`, `photos/`) | bucket `library`: `<user>/projects/<id>/...` |
| files in `Objects/<id>/` (`model.usdz`, `thumb.jpg`; not the scan's `Images/`, `Checkpoint/`) | bucket `library`: `<user>/objects/<id>/...` |
| `@AppStorage` flags (intro seen, demo seeded, realistic furniture) | not synced: per-device settings |

Each row also holds a `files` manifest (size and modification time per file). A sync pass runs on launch, on return
to the foreground and 2 s after a change. Rooms and objects are last-writer-wins on `updatedAt` (a database trigger
rejects stale writes), files per file by modification time. Deletes are tombstones (`deleted_at`), sent once online.
The backend stores nothing.

Setup, once per Supabase project:

1. Apply `supabase/migrations/` (tables, row-level security, the private `library` bucket and its policies), with the
   Supabase CLI (`supabase db push`) or the SQL editor.
2. Dashboard > Authentication > Sign In / Providers: turn on **Allow anonymous sign-ins**. Each install signs in as
   its own anonymous user; row-level security keeps every user to their own rows and files.
3. In `backend/.env` set `SUPABASE_URL` and `SUPABASE_PUBLISHABLE_KEY` (Project Settings > API Keys), then run
   `scripts/run_local.sh` and rebuild: the script adds them to `APIConfig.json`. It refuses secret / service_role keys.

Limits: the anonymous session lives in the Keychain, so it survives a reinstall, but a second device is a different
user (no shared library) until accounts get a real sign-in. Files are capped at 50 MB each.

## Backend (run locally)

The demo runs the backend on your Mac. Nothing is deployed. Run every command below from the repo root.

```sh
python3 -m venv backend/.venv && backend/.venv/bin/pip install -r backend/requirements.txt pytest
(cd backend && .venv/bin/pytest -q)          # self-check
cp backend/.env.example backend/.env         # gitignored; read automatically on start
openssl rand -hex 32                         # paste as APP_SHARED_SECRET in backend/.env
```

Config lives in `backend/.env`. It is parsed with python-dotenv (quotes and inline comments handled, no interpolation), never executed, and only known keys are read:
- `MOCK` (default `1`): canned responses, no keys needed. Set `MOCK=0` for real providers.
- `APP_SHARED_SECRET`: generate with `openssl rand -hex 32`. Set a fixed one: without it, each LAN run makes a new
  session secret, and you must rebuild the app after every run. With `MOCK=0` the backend refuses every request without a secret.
- Provider keys: `LLM_API_KEY` (+ `LLM_MODEL`), `IMAGE_API_KEY` (+ `IMAGE_MODEL`, `IMAGE_SIZE`), `SHOPPING_API_KEY`,
  `BROWSER_USE_API_KEY` (+ `BROWSER_USE_MODEL`, `BROWSER_USE_MAX_COST`), `FAL_KEY`.
- Limits: `MAX_UPLOAD_MB=10`, `MAX_RESPONSE_MB=20`, `USDZ_MAX_MB=8`, `USDZ_MAX_FACES=80000`.

Start it from the repo root:

```sh
scripts/run_local.sh               # iPhone on the same Wi-Fi: Mac's LAN IP, binds 0.0.0.0
scripts/run_local.sh --sim         # Simulator only: 127.0.0.1, binds 127.0.0.1
scripts/run_local.sh --port 9000   # any mode, another port (default 8000)
```

The script writes the gitignored `RoomVibe/Core/Networking/APIConfig.json` (base URL + secret, file mode 0600), then
serves on `0.0.0.0:<port>` (LAN) or `127.0.0.1:<port>` (`--sim`). The config is bundled into the app, so rebuild and
reinstall the app after it changes. The secret ends up in the app build, which is fine for a local demo.
`--sim` rewrites the config to 127.0.0.1: before a device build, run the script again without `--sim` and rebuild.
Check the server: `curl http://<ip>:<port>/health`.

On a physical iPhone:
- The iPhone and the Mac must be on the same Wi-Fi.
- On first launch iOS asks for Local Network permission. Allow it, or every request fails.
  If it was denied: Settings > Privacy & Security > Local Network > RoomVibe on, then relaunch the app.
- If macOS asks "Allow incoming connections" for Python, allow it. Otherwise the phone gets no answer.
- The app allows plain `http` on the local network only (`NSAllowsLocalNetworking`).

Providers: Gemini image editing (`/render`, Interactions API), Claude (`/vibe/analyze`), SerpAPI Google Shopping
(`/vibe/products`), Browser Use agents (`/vibe/shop`), fal SAM 3D Objects (`/vibe/model3d`).
With `MOCK=0`, an endpoint whose key is missing returns 501. Provider keys live only in `backend/.env`, never in the app.
The app holds `APP_SHARED_SECRET`, which anyone with the build can read: it is an access gate, not a secret. Rotate it after the demo.

Without `APIConfig.json` the app calls `http://127.0.0.1:8000`, which works only from the Simulator.
If the app still calls 127.0.0.1 after running the script, the file did not decode: check it is valid JSON (the Xcode
console logs the error), then rebuild.

## Work split

See `docs/PLAN.md` (scope, ownership, 48h timeline) and the per-person handoff prompts in `docs/`:
A = scanning (`handoff-A-scanning.md`), B = Designer/visuals/AR (`handoff-B-designer.md`),
C = backend/AI/render/vibe (`handoff-C-backend-ai.md`).

## Status / known gaps

- Scanning only runs on a LiDAR device; verify on the demo phone early.
- Custom orbit camera: drag empty space to orbit, drag an object to move it, pinch to zoom, twist to rotate the selection.
- Placements clamp to the room's bounding rectangle, not the exact wall outline.
- Make it real is wired end to end: the sand "Make it real" pill on Room detail and in the fullscreen Designer
  (`DesignerView.makeItReal()`) snapshots the 3D view and its camera, then opens `RenderView` (`Features/Render/`),
  which calls `/render` and shows a before/after slider with a Dollhouse / Photo switch.
  Tested in the Simulator against `MOCK=1` (the mock echoes the snapshot back). Not yet tried against the real
  Gemini backend on a device: that needs the Vercel deploy and `APIConfig.json` above.
  The app pings `/health` once at launch to wake a cold Vercel function. An offline render shows the last cached
  render of that room and view. While the sheet is open, a failed or cached render re-runs by itself when the
  network comes back (not yet tested).
- Vibe mode (`Features/Vibe/`) is built and was tested in the Simulator against `MOCK=1`, but nothing opens it.
- Not built yet: AR view, generic furniture USDZ swap.
- Cloud library: built and compiled, not yet tested end to end against the Supabase project (anonymous sign-ins
  must be on first).
