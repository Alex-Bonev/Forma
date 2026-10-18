# Spec: Designer editing, placeholders, scan-to-replace

Status: **built** (`a/realism`), UI replaced by the Paper "forma" design (`b/forma-ui`, Michelle). Owner: A (Alex). This records the target behavior so later work stays consistent.

> **Update:** Michelle decided the Paper design fully replaces the old Designer UI. The bottom selection card, bottom library buttons and "Show hidden" button are gone. All selection actions now live on the selected row of the **Objects panel** (top bar > Objects, opens automatically on selection). The panel is a **bottom sheet** (Paper E2, E2a, E2b, E3): drag its grabber to resize; it snaps to peek (180 pt), medium (440 pt) or large (screen height minus 120 pt). The room recenters above it, and the vibe pill and view controls stay where they are. Behavior below is otherwise unchanged.

## Behavior

- **Select:**
  - Tap a placement (library scan or catalog item) or scanned RoomPlan furniture, when nothing is selected.
  - The selection is sticky:
    - A tap on another object is ignored.
    - Only a tap on empty space deselects.
    - A long press (0.4 s, with a haptic) on another object switches to it.
  - With a placement selected, a one-finger drag that starts on or near any object moves the selected one. The hit test prefers the selection, with a 25 cm margin. A drag on empty space orbits.
  - Marker (`Theme.selection` blue):
    - Corner brackets around the object's box.
    - A solid floor ring and a tinted disc.
    - Sizes divide out the object's scale.
  - Selecting opens the item's row in the Objects panel.
  - Marked items are orange boxes created by tapping during a room scan.
- **Selection card** (replaces the Objects list while something is selected; sized to its content so the room stays in view above it):
  - Header: icon, name and size, then a **lock** icon (placements only), the **eye** (hide/show) and **✕** (deselect).
  - One row of action tiles:
    - Placements: **Rotate** (22.5°, disabled when locked), **Size**, **Scan real** (LiDAR only), **Remove**. Remove asks "Remove <name>?" and confirms with "Remove from room".
    - Scanned furniture: **Replace**, **Size**, **Scan real**. Marked items also get **Use <suggestion>** when Vision found one.
  - Shopped products also show their listing link and **Make it 3D**.
  - **Size** opens inside the card, never as a sheet:
    - Width, depth and height steppers.
    - An "Above floor" slider.
    - Reset Size, Put on Floor (when raised) and Done.
    - Every change shows live in the room above.
  - No selection: the resizable list (peek, medium or large) with a lock badge on locked rows, and Add object.
  - Twist also rotates, unless the item is locked.
- **Scanned furniture moves too:**
  - Dragging it, twisting it or tapping Rotate swaps in its movable copy and keeps the same gesture going. The copy uses the same model, box, spot and facing.
  - The copy is the same placement that Size already creates. The original is removed for good.
  - Tap-marked boxes still use Replace or Use <suggestion>.
- **Lock:** the lock icon on the card. A locked placement ignores one-finger drag and twist. Size and Remove still work. The floating Lock pill was removed.
- **Undo:** Remove and Replace show a 5 s "Undo" bar that restores the project snapshot. Selecting anything dismisses it.
- **Drag bounds:** the footprint stays inside the walls' rectangle, then inside `RoomModel.floorOutline` (`FloorClamp`).
- **Size** opens a sheet with live changes:
  - Width / height / depth in 5 cm steps (`Placement.scale`). "Reset Size" returns to `Placement.fitScale` (the size it was fitted to from a scanned box), else the model's natural size.
  - Height above floor, 0–2.4 m (`Placement.position.y`), for wall-mounted items. "Put on Floor" resets it.
  - Scanned furniture: Edit converts it into a placement with the same model fitted to RoomPlan's box. The original is removed through `Project.removedRoomObjects` (never restored by the eye toggle).
- **Bottom bar:** "Make it real", "Add object", and a cart icon once the room has a shopped product (it opens that room's cart, see `cart.md`).
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
- `Placement.locked` (nil = unlocked)
- `Project.hiddenRoomObjects` (user Hide only), `removedRoomObjects` (replaced), `Placement.fitScale`, `wallFinish` (preset id or `paint:#RRGGBB`), `floorFinish`
- `RoomModel.Box.attributes`

## Tests

`RoomVibeUITests`: drag/orbit/pinch, lock pill (shows on tap, hides on other touches, locked chair does not move),
catalog + select/hide/show/replace through the Objects panel, Custom Box editor, Reset Size, delete undo, rename object and room. `scripts/clamp_check`. Uninstall the app before running so saved state doesn't leak between tests.
