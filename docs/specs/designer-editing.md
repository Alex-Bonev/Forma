# Spec: Designer editing, placeholders, scan-to-replace

Status: **built** (`a/realism`), UI replaced by the Paper "forma" design (`b/forma-ui`, Michelle). Owner: A (Alex). This records the target behavior so later work stays consistent.

> **Update:** Michelle decided the Paper design fully replaces the old Designer UI. The bottom selection card, bottom library buttons and "Show hidden" button are gone. All selection actions now live on the selected row of the **Objects panel** (top bar > Objects, opens automatically on selection). Behavior below is otherwise unchanged.

## Behavior

- **Select:**
  - Tap a placement (library scan or catalog item) or scanned RoomPlan furniture.
  - A dashed floor ring shows the selection, and its row in the Objects panel opens.
  - Marked items are orange boxes created by tapping during a room scan.
- **Selected row** (Objects panel): the item's name and size, then labeled actions. Hide is the eye on every row, not an action.
  - Placements: **Rotate** (22.5°), **Remove**, **Size**, **Scan real** (LiDAR only).
  - Scanned furniture: **Replace**, **Size**, **Scan real**.
  - Marked items: **Use <suggestion>** (if Vision found one), **Replace**, **Scan real**.
  - Twist also rotates. No Done buttons (tap empty space deselects).
- **Undo:** Remove and Replace show a 5 s "Undo" bar that restores the project snapshot. Selecting anything dismisses it.
- **Drag bounds:** the footprint stays inside the walls' rectangle, then inside `RoomModel.floorOutline` (`FloorClamp`).
- **Size** opens a sheet with live changes:
  - Width / height / depth in 5 cm steps (`Placement.scale`). "Reset Size" returns to `Placement.fitScale` (the size it was fitted to from a scanned box), else the model's natural size.
  - Height above floor, 0–2.4 m (`Placement.position.y`), for wall-mounted items. "Put on Floor" resets it.
  - Scanned furniture: Edit converts it into a placement with the same model fitted to RoomPlan's box. The original is removed through `Project.removedRoomObjects` (never restored by the eye toggle).
- **Create:** Objects panel > "Add object" → "Your scans" or the catalog ("Custom Box" first), then size it.
- **Replace:**
  - Catalog items stretch to RoomPlan's measured box. Library scans keep real scale.
  - Mounting height is preserved: the bottom of RoomPlan's box above the floor.
- **Scan to replace** (camera icon, LiDAR only):
  - Opens Object Capture.
  - The saved scan replaces the selected placeholder at the same spot, facing and height. The placeholder is removed, not hidden.
  - Marked items face away from the nearest wall.
- **Wall-mounted objects:**
  - Object Capture in this SDK has no capture mode that skips an object's back.
  - Scan one pass without flipping (≥10 photos); the back is guessed but sits against the wall.
  - Then use scan-to-replace on the item's box.
- **Rename room:** tap the title in the Designer > Rename (also long-press or swipe in Home).
- **View controls:** Reset view, Room Photos (if the scan has photos), Finishes (wall and floor presets, Matched Paint, Realistic Models toggle), Cutaway walls. No top-view toggle (removed at Alex's request).

## Data (all additive and optional; old saves decode)

- `Placement.scale`
- `Placement.position.y` = mounting height
- `Placement.catalogItem`
- `Project.hiddenRoomObjects` (user Hide only), `removedRoomObjects` (replaced), `Placement.fitScale`, `wallFinish` (preset id or `paint:#RRGGBB`), `floorFinish`
- `RoomModel.Box.attributes`

## Tests

`RoomVibeUITests`: drag/orbit/pinch, catalog + select/hide/show/replace through the Objects panel, Custom Box editor, Reset Size, delete undo, rename object and room. `scripts/clamp_check`. Uninstall the app before running so saved state doesn't leak between tests.
