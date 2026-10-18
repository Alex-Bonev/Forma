# Spec: Grounded "Make it real"

Status: **built** (`a/grounded-render`). Owner: A (inputs), C (endpoint and screen).

## Problem

Renders were more elaborate than the real room. Causes:
- The prompt invited extras ("warm natural light", "small decor such as plants, rugs and lamps is fine").
- The layout text was wrong:
  - It said "white walls" for every room.
  - It called furniture "colored blocks", which no longer matches the realistic models on screen.
  - It left out catalog items.
  - It still listed hidden and replaced scanned objects.
- The image model never saw the real room.

## Behavior

- **App** (`Features/Render/RenderInputs.swift`):
  - `scene(project:room:objects:)` builds the input for `LayoutDescription` and `StructureMap`:
    - Drops `hiddenRoomObjects` and `removedRoomObjects`.
    - Adds every placement as a sized object, with `Placement.scale` baked in.
    - Marks catalog items as stand-ins.
  - `finishes(_:)` gives the wall and floor sentence (Matched Paint hex, or the preset name).
  - `photos(projectID:)` picks up to 3 scan photos:
    - Only mostly-level shots.
    - Spread by viewing direction.
    - Turned upright from the camera pose.
    - Scaled to ≤ 1024 px.
- **Backend** (`/render`):
  - New optional multipart field `photos`, repeatable, capped at 3, inside the 4 MB total.
  - The prompt says:
    - Image 1 is the truth for the camera, the layout and positions.
    - The photos are the truth for looks: wall color, flooring, real furniture materials, light.
    - Add nothing that isn't in image 1.
    - Ignore clutter and people in the photos.

- **Vibe mode** (style words and/or `style_ref`) uses `RESTYLE_RULES` instead: same layout, restyled looks.
  Faithful rules apply only to a plain Make it real.
- Shopped products (`Placement.product`, from Vibe) are named by their listing title in the layout.

## Checks

- `backend/test_main.py::test_render_scan_photos`: image numbering, the 3-photo cap and the rules text.
- Simulator, UCLA dorm, real Gemini:
  - The chosen photos are upright and cover the desk, the window and the loft bed.
  - The render has the real window view, wooden loft bed and chairs, plain walls and no added decor.

## Known gaps

- Empty areas in the snapshot (such as an L-room's cut-out corner) can still get invented geometry.
- Stand-ins sometimes keep the 3D model's look over the photos'.
