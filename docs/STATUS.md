# RoomVibe — Status, open work, and handoff (Alex's track)

Last updated: 2026-10-17, branch `a/polish` (off `main`; PRs #1–#3 merged).

## Done (on `a/realism` unless noted)

**Scanning (handoff A)**
- **Room scan:** RoomPlan with a review step before saving.
  - Saves are axis-aligned.
  - Saves the floor outline and RoomPlan furniture attributes.
  - Tap-to-mark items RoomPlan misses (raycast into its ARSession).
  - About 40 photos are captured during the scan (`RoomPhotos`).
  - Matched Paint wall colour from the photos (`RoomPhotoMath`).
  - On-device Vision (`SceneClassifier`): Brick/Oak finishes, and a suggestion for each marked item.
- **Object scan:**
  - Object Capture: passes, flip, ≥10 photos.
  - Reconstruction: progress, retry, thumbnail.
  - Then save to the library.
  - Scan-to-replace a selected placeholder.

**Designer**
- **Navigation:** UIKit touch layer.
  - Orbit with momentum, two-finger pan, pinch zoom, twist rotate, tap select.
  - Walls between the camera and the room hide.
  - Controls: Reset, Room Photos, Finishes, Cutaway.
- **Furniture:**
  - Priority: Poly Haven photoreal (toggle) → rounded procedural (20 keys) → Kenney.
  - Catalog of 22 items, including Custom Box.
  - Replace or Hide scanned furniture.
  - Edit size and mounting height.
- **Finishes:**
  - Walls: 6 presets + Matched Paint. Floors: 5 presets.
  - CC0 textures. Synchronous load, because the async loader crashes RealityKit.

**Docs:**
- `PLAN.md` holds scope and ownership.
- Specs: `docs/specs/{designer-editing,rounded-furniture,scan-intelligence,finishes-assets}.md`.
- Demo run sheet: `docs/DEMO.md`.

**Tests**
- `RoomVibeUITests`: 5 tests covering gestures, catalog/hide/replace, editor, Vision suggestion, rename.
- Self-checks: `scripts/align_check`, `scripts/photo_check`, `scripts/scene_check`.
- `backend/test_main.py`.

## Open issues

Round 2 (Alex, Oct 17), all fixed on `a/polish`:
1. **Selection not obvious:** blue corner brackets around the bounds plus the floor disc.
2. **Scan Real only hid the marked item:** Replace / Size / Scan Real now put the RoomPlan object in
   `Project.removedRoomObjects`, so "Show hidden" can no longer bring back a duplicate. Hide stays restorable.
3. **"Reset to Natural Size" made duplicates:** not reproducible in the Simulator. Root-cause candidates fixed:
   the replaced original came back via "Show hidden" (see 2); Reset jumped to the catalog default size (now
   "Reset Size" returns to `Placement.fitScale`); `spawn` is now idempotent per placement id.
4. **Rename a room:** tap the Designer title → Rename (Home long-press/swipe still works).

Also added: undo for Delete / Hide (5 s bar), drags clamped to the scanned floor outline (`FloorClamp`, `scripts/clamp_check`).

## Unverified on device (needs Alex's phone)

- **Photo capture during a room scan:** orientation, colour, and the shared frame between photos and RoomPlan walls.
- **Matched Paint:** whether the colour is accurate.
- **Vision during scanning:** the marked-item crop and the brick/wood vote.
- **Tap-to-mark:** where the markers land.
- **Scan-to-replace:** the Object Capture path end to end.
- **Floor-outline clamp:** on a real (non-rectangular) scan. If items jump oddly while dragging, the outline frame is off.

## Future work (A)

- Bundle the final demo room and chair (`scripts/pull_demo_assets.py`), then rehearse with `docs/DEMO.md`.
- **Demo gap:** nothing opens David's Render/Vibe screens. Needs B's "Make it real" toolbar button + merging `c/backend-ai`
  (merges cleanly with `a/polish`). Michelle has no branch pushed yet.
- Render the floor from `floorOutline` instead of the walls' bounding box (B's room visuals).
- Coordinate with Michelle (her room visuals) and David (`c/backend-ai`; review comment posted on commit 6082487).

## Handoff prompt (paste into a fresh session)

> You are continuing Alex's track on RoomVibe (iOS 18 SwiftUI + RoomPlan + Object Capture + RealityKit) in `~/Desktop/CodeProjects/RoomVibe`, branch `a/polish`.
> 1. Read `docs/STATUS.md`, `docs/PLAN.md` and every file in `docs/specs/` first.
> 2. Talk caveman-terse, write lazy-but-correct code (ponytail), and use the apple-design skill for UI.
> 3. Fix the "Open issues" in STATUS.md, in order.
> 4. **Build:** `xcodebuild -project RoomVibe.xcodeproj -scheme RoomVibe -destination 'generic/platform=iOS' -derivedDataPath build CODE_SIGNING_ALLOWED=NO build`.
> 5. **Tests:** `xcodebuild test -project RoomVibe.xcodeproj -scheme RoomVibe -destination 'id=69EC08B8-433D-4F6D-99EE-E1DA147D52A9' -derivedDataPath build`. Uninstall `com.alexbonev.roomvibe` first.
> 6. **Visual checks:** Simulator `-demo` launch + `xcrun simctl io … screenshot`. Wait about 14 s for the scene.
> 7. **Device (iPhone 17 Pro):**
>    - Device id `16AB1A85-AA19-59BA-8669-767F934D1CDA` (destination `id=00008150-001A5D893A2B401C`).
>    - Build with `-derivedDataPath build-device -allowProvisioningUpdates`, then install with `xcrun devicectl device install app`.
> 8. **Committing:**
>    - Commit often and push to `a/realism`.
>    - Retry if `.git/index.lock` is busy (Xcode grabs it).
>    - Never commit `.claude/` or `build*`.
> 9. **Delegating:** use worktree subagents with a written spec in `docs/specs/`. Update specs and STATUS.md whenever scope changes.
> 10. **Known traps:**
>     - The async `TextureResource(contentsOf:)` crashes RealityKit; use `.load` sync.
>     - RealityView renders under the bottom panel, so pick with `content.ray(through:)`.
>     - RoomPlan objects face +Z; Kenney and Poly Haven models face −Z, so turn them 180°.
>     - iOS 26 content swipe-back must wait for the pan (`shouldBeRequiredToFailBy`).
