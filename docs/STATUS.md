# RoomVibe — Status, open work, and handoff (Alex's track)

Last updated: 2026-10-17, branch `a/grounded-render`. `main` has PRs #1–#16 merged. Open: #17 (David, vibe shopping).

## Done

**Scanning (A)**
- **Room scan:** RoomPlan with a review step.
  - Saves are axis-aligned, with the floor outline and attributes.
  - Tap-to-mark missed items; Vision suggests what they are.
  - About 40 photos per scan.
  - Matched Paint wall color: upper wall only, furniture occlusion test, lit-wall percentile. Tuned on a real scan with `scripts/paint_check`.
- **Object scan:** Object Capture, then reconstruction, then the library. Scan Real replaces a placeholder in place.

**Designer**
- Orbit, pan, pinch and twist; tap to select (brackets and a ring).
- Undo for Delete and Hide. Removed vs. hidden scanned items. Reset Size. Lock in place (B).
- L-shaped rooms: the floor follows the scanned outline, wall cutaway sides come from the floor polygon, and drags are clamped to the outline.
- Finishes: 12 wall presets plus Matched Paint, 10 floors. Furniture is photoreal, rounded procedural, or Kenney.
- Room thumbnails come from the default 3D view (`thumb.jpg`). Library tiles show the scan's own thumbnail.

**Make it real (C's screen, A's inputs)**
- Snapshot plus structure map, a layout text built from what the Designer shows (`RenderInputs`), and up to 3 real scan photos as ground truth.
- The prompt asks for a faithful render and adds nothing. See `docs/specs/grounded-render.md`.

**Shared**
- The UCLA dorm (room, 40 photos, thumbnail) is bundled and seeded once on every install. Demo Living Room and Demo Chair come from Load Demo Data.
- New Paper "forma" UI (B).

**Cloud library (C, branch `c/supabase`)**
- Rooms, objects and My Vibes mirror to Supabase (tables + private `library` bucket). See README "Cloud library" and `docs/specs/supabase-storage.md`.
- Three-way file merge: file deletes sync both ways. Render cache writes trigger a pass.
- UI-test runs (`-demo`, `-fresh`, `-seedVibe`) never sync. Dorm seeding waits for the first pass.
- Backend accepts the app user's Supabase token (JWKS) as well as `X-App-Secret`.

**Tests**
- 11+ UI tests (`RoomVibeUITests`).
- `backend/test_main.py`.
- Self-checks: `scripts/{align,photo,scene,clamp,floor,paint}_check`.

## Open

1. **Backend hosting:** not deployed to Vercel. The app runs against Alex's Mac through a Cloudflare quick tunnel (the URL changes on every restart). Owner: C.
2. **Make it real accuracy:**
   - The render can still invent geometry where the snapshot shows empty space, such as the dorm's cut-out corner.
   - Stand-in furniture sometimes keeps its 3D-model look instead of the photos'.
3. **Demo Chair:** still the procedural stand-in. Bundle a real scan with `scripts/pull_demo_assets.py`.
4. **Rehearsal:** rehearse with `docs/DEMO.md` and record a backup video.
5. **AR view** (stretch #3): not started.
6. **Restyle:** the scan screens (RoomScan, ObjectScan, RoomPhotos) still use system styling, not forma.
7. **Rescan room:** creates a new project and drops hidden/removed items. Rescanning in place would need `ProjectStore` support.
8. **Cloud library** (owner: C): built and reviewed, not yet run end to end against the real project (blocked on step 2). Manual steps, same list as README "Cloud library":
   1. Migrations: both already applied to `hoihybbcwljxkambccqd` (`20261018062400_library`, `20261018080825_saved_vibes`). Only a new project needs them.
   2. Dashboard > Authentication > Sign In / Providers: turn on **Allow anonymous sign-ins**. Until then nothing can sign in.
   3. Recommended: Authentication > Attack Protection, turn on CAPTCHA or keep the sign-up rate limit low.
   4. `backend/.env` (create it first, see README "Backend"): set both `SUPABASE_URL=https://hoihybbcwljxkambccqd.supabase.co` and `SUPABASE_PUBLISHABLE_KEY`, else the script prints "Cloud library: off". Then `scripts/run_local.sh` and rebuild.
   5. Demo phone: scan a room and an object, reinstall, check the library comes back.
   6. Merge `c/shopped-render` before the `c/supabase` PR, or expect conflicts in `ProjectStore.swift` and `DesignerView.swift`.

   Done: the Simulator end-to-end check (rooms, an object and a vibe reached the tables and the bucket; a local rename, a cloud rename, a local delete, a cloud tombstone and a single-file delete all round-tripped).

## Unverified on device

- **Matched Paint:** the new algorithm on a fresh scan.
- **Vision:** marked-item suggestions.
- **Tap-to-mark:** where markers land.
- **Scan Real:** end to end.
- **Dragging:** in a real L-shaped room.

## Handoff prompt (paste into a fresh session)

> You are continuing Alex's track on RoomVibe (iOS 18 SwiftUI + RoomPlan + Object Capture + RealityKit + FastAPI backend) in `~/Desktop/CodeProjects/RoomVibe`. Branch off `main` as `a/<topic>`.
> 1. Read `docs/STATUS.md`, `docs/PLAN.md`, `docs/wiring-for-A.md` and every file in `docs/specs/` first.
> 2. Talk caveman-terse, write lazy-but-correct code (ponytail), and use the apple-design skill for UI (forma: `Core/Theme.swift`).
> 3. **Build:** `xcodebuild -project RoomVibe.xcodeproj -scheme RoomVibe -destination 'generic/platform=iOS' -derivedDataPath build CODE_SIGNING_ALLOWED=NO build`.
> 4. **Tests:**
>    - App: `xcodebuild test … -destination 'id=69EC08B8-433D-4F6D-99EE-E1DA147D52A9' -derivedDataPath build`. Uninstall `com.alexbonev.roomvibe` first.
>    - `-demo -fresh -room "<name>"` opens a room.
>    - Backend: `cd backend && .venv/bin/pytest -q`.
> 5. **Device (iPhone 17 Pro):** destination `id=00008150-001A5D893A2B401C`, `-derivedDataPath build-device -allowProvisioningUpdates`, then `xcrun devicectl device install app --device 16AB1A85-AA19-59BA-8669-767F934D1CDA …`.
> 6. **Backend for the device:**
>    - `cd backend && .venv/bin/uvicorn main:app --port 8000 --env-file .env`.
>    - Alex runs `cloudflared tunnel --url http://localhost:8000`.
>    - Put the URL into the gitignored `RoomVibe/Core/Networking/APIConfig.json`.
> 7. **Git:**
>    - Commit often and open PRs to `main`; rebase on `main` before pushing.
>    - Never commit `.claude/`, `build*`, `APIConfig.json`, `backend/.env`.
>    - `xcodegen` rewrites `project.pbxproj` formatting; check that noise out.
> 8. **Known traps:**
>    - The async `TextureResource(contentsOf:)` crashes RealityKit.
>    - Pick with `content.ray(through:)`.
>    - RoomPlan objects face +Z; Kenney and Poly Haven models face −Z.
>    - Scan photos are stored in sensor orientation (`RenderInputs.orientation` turns them upright).
>    - `RealityRenderer` is not in the iOS SDK (no offscreen renders).
