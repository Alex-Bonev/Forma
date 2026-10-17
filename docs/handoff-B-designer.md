# Handoff — Teammate B: Designer, room visuals, polish, AR

Paste this into Claude Code from the repo root. Read `docs/PLAN.md` first; it has the full product, timeline and rules.

## Who you are on the team

You own everything the user **sees and touches after a scan**: the 3D dollhouse, placing/moving objects, the Home screen,
visual polish, the app icon, and the AR view stretch goal. You have a Mac and a LiDAR iPhone, so you can test on device.

Teammates (do not do their work):

- **A (Alex):** room scanning and object scanning (`Features/RoomScan/`, `Features/ObjectScan/`), demo assets, `project.yml`.
- **C:** backend, networking, snapshot capture, render and vibe screens (`backend/`, `Core/Networking/`, `Features/Render/`, `Features/Vibe/`).

## Files you own

- `RoomVibe/Features/Designer/` — `DesignerView.swift`, `RoomBuilder.swift`
- `RoomVibe/Features/Home/`
- `RoomVibe/Features/AR/` (create when you start AR)
- `RoomVibe/Assets.xcassets` (create for app icon / accent color)
- Shared data layer (you own it, A reviews): `Core/Models.swift`, `Core/ProjectStore.swift`, `App/RoomVibeApp.swift`

Do not edit files outside this list. If you need a change elsewhere, ask the owner.

## Setup

```sh
git clone https://github.com/Alex-Bonev/RoomVibe.git && cd RoomVibe
cp Config/Local.xcconfig.example Config/Local.xcconfig   # fill in your team ID + unique bundle prefix
open RoomVibe.xcodeproj
```

Run on your phone (README has the Developer Mode steps). Add `-demo` as a launch argument
(Product > Scheme > Edit Scheme > Run > Arguments) to open the demo room directly. Work on branches `b/<topic>`; small PRs to `main`.

## How the Designer works today

- `RoomModel` (in `Core/Models.swift`) is our slim copy of RoomPlan output: walls, doors, windows, openings, objects,
  each a `Box { label, dimensions, columns }` (columns = 4×4 transform). Walls/doors/windows have `dimensions.z == 0`.
- `RoomBuilder.build(_:wallScale:)` turns it into entities, centered on the room with the floor at y = 0. Placements live in
  plain scene coordinates.
- `DesignerView` uses `content.camera = .virtual` plus its **own** orbit camera (`Orbit` azimuth/elevation/distance) and its own
  ray math (`ray(at:)`, `floorPoint(at:)`, `hitPlacement(at:)`). Apple's `.realityViewCameraControls(.orbit)` was removed on purpose:
  it swallowed object drags and let the camera clip through walls. Do not bring it back.
- Gestures: one-finger drag on object = move on floor; on empty space = orbit. Pinch = zoom (clamped by `zoomRange`).
  Two-finger twist = rotate selected object. Tap = select / deselect. Buttons = rotate ±22.5°, delete.
- Placements persist through `store.update(project)` in `commit()`.

## Tasks, in order

Each task ends with something demo-able. Commit after each.

1. **Verify on device (H0–2).** Drag moves the chair, orbit and zoom feel right, zoom cannot enter the room, twist rotates.
   Tune constants (`0.008`, `0.005`, `zoomRange`, elevation clamp `0.25...1.5`). If hit testing is off, check `ray(at:)` against
   the view size (the RealityView ignores the bottom safe area).
2. **Interaction polish (H2–8).** Use the `apple-design` skill principles: instant feedback on touch-down, 1:1 tracking.
   - Selection highlight (e.g. a soft ring/disc on the floor under the selected object, or a subtle scale/tint).
   - Smooth camera: animate orbit changes with a critically damped spring instead of jumping, and add momentum on release.
   - Undo for delete (a toast with "Undo" for ~4 s) instead of no-confirmation delete.
   - Haptic on pick-up and drop (`.sensoryFeedback`).
   - Optional: clamp to the real wall outline instead of the bounding rectangle (see the `ponytail:` comment in `clamp`).
3. **Room visuals (H8–12).** Make the dollhouse read beautifully:
   - Floor from the actual wall outline instead of a rectangle.
   - Walls: slightly thicker, soft off-white, maybe darker top cap so the cutaway reads clearly.
   - Doors as gaps or frames, windows as light glass. Soft shadows. Nicer label style.
   - Top-down view toggle (animate camera to elevation ≈ 1.5).
4. **Tier 2 furniture (H12–20).** Replace category boxes with generic USDZ models scaled to each box's dimensions.
   Ask A for the model files (A owns `Resources/DemoData/`). Keep boxes as fallback for unknown categories.
5. **"Make it real ✨" hook (by H20).** Add one toolbar button in `DesignerView` that presents C's
   `RenderView(snapshot: UIImage)`, using C's `captureDesignerSnapshot() -> UIImage?` from `Features/Render/Snapshot.swift`.
   Until C ships those, present a placeholder sheet. Agree the exact names with C in chat before writing it.
6. **App polish (H20–24).** App icon, accent color, Home screen empty states and room thumbnails, transitions.
7. **AR view (H24–34, only if render is solid).** `Features/AR/`: "View in AR" button in Designer → `RealityView` with
   world tracking (or `ARView`) → tap a detected horizontal plane to place the selected scanned object at real scale.
   Must not break anything when the device lacks LiDAR (hide the button).
8. **Freeze at H40.** Bug fixes only; join demo rehearsals.

## Acceptance checks

- Scanned chair in scanned room can be dragged, rotated, deleted, and is still there after killing the app.
- Camera never clips inside walls; orbit and zoom feel smooth at 60 fps on device.
- Simulator with `-demo` still works (no LiDAR code paths in your files).

## Rules

- Check SDK headers / Apple docs before using a RealityKit API; mark anything uncertain `// VERIFY:`.
- Keep `RoomModel` changes additive with optional fields; old saved rooms must still decode.
- No third-party dependencies. No API keys in the app.
