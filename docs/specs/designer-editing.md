# Spec: Designer editing, placeholders, scan-to-replace

Status: **built** (`a/realism`). Owner: A (Alex). This records the target behavior so later work stays consistent.

## Behavior

- **Select:**
  - Tap a placement (library scan or catalog item) or scanned RoomPlan furniture.
  - A blue floor disc shows the selection.
  - Marked items are orange boxes created by tapping during a room scan.
- **Edit** (sliders icon) opens a sheet with live changes:
  - Width / height / depth in 5 cm steps (`Placement.scale`).
  - Height above floor, 0–2.4 m (`Placement.position.y`), for wall-mounted items. "Put on Floor" resets it.
  - Scanned furniture: Edit converts it into a placement with the same model fitted to RoomPlan's box. The original is hidden through `Project.hiddenRoomObjects`.
- **Create:** Add Item → "Custom Box" (first item), then size it.
- **Replace:**
  - Catalog items stretch to RoomPlan's measured box. Library scans keep real scale.
  - Mounting height is preserved: the bottom of RoomPlan's box above the floor.
- **Scan to replace** (camera icon, LiDAR only):
  - Opens Object Capture.
  - The saved scan replaces the selected placeholder at the same spot, facing and height.
  - Marked items face away from the nearest wall.
- **Wall-mounted objects:**
  - Object Capture in this SDK has no capture mode that skips an object's back.
  - Scan one pass without flipping (≥10 photos); the back is guessed but sits against the wall.
  - Then use scan-to-replace on the item's box.
- **View controls:** Reset view, Room Photos (if the scan has photos), Finishes (wall and floor presets, Matched Paint, Realistic Models toggle), Cutaway walls. No top-view toggle (removed at Alex's request).

## Data (all additive and optional; old saves decode)

- `Placement.scale`
- `Placement.position.y` = mounting height
- `Placement.catalogItem`
- `Project.hiddenRoomObjects`, `wallFinish` (preset id or `paint:#RRGGBB`), `floorFinish`
- `RoomModel.Box.attributes`

## Tests

`RoomVibeUITests`: drag/orbit/pinch, catalog + select/hide/restore/replace, Custom Box editor, rename.
