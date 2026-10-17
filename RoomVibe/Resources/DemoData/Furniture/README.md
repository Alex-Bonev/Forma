# Generic furniture (Tier 2 box swap)

One USDZ per RoomPlan `CapturedRoom.Object.Category`, named after the category's case name
(the same string as `RoomModel.Box.label`): `sofa.usdz`, `table.usdz`, `chair.usdz`, ... `fireplace` has no model.

- Source: Kenney Furniture Kit 2.0, CC0 (public domain), https://kenney.nl/assets/furniture-kit
- Regenerate: `scripts/obj_to_usdz.py "<kit>/Models/OBJ format" RoomVibe/Resources/DemoData/Furniture`
- Units are arbitrary and the origin is at a corner (z from 0 to depth): scale each model's `visualBounds` to the box's
  `dimensions` and center it, rather than relying on the model's own size or origin.
- Facing: backs are toward +Z (front faces -Z). VERIFY against a real scan which way RoomPlan objects face
  (e.g. a sofa against a wall: its back should touch the wall) and rotate 180° if needed.
