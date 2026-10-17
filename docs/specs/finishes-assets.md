# Spec: More wall and floor finishes

Status: **ready to build** (delegated). Owner: A (Alex).

## Goal

Broaden the finishes menu with more realistic CC0 materials so rooms can be dressed convincingly.

## Today

`RoomVibe/Features/Designer/Finishes.swift`:
- Walls: White, Warm Plaster, Beige, Brick, Sage, Navy (+ Matched Paint).
- Floors: Light, Oak, Planks, Marble, Concrete.

Textures live in `RoomVibe/Resources/DemoData/Finishes/finish_<polyhaven_id>.jpg`. They are Poly Haven diffuse maps at 1k, recompressed with `sips -s formatOptions 75`. `tile` = meters per texture repeat.

## Add

- **Walls, about 6:** e.g. white subway / bathroom tiles, wood paneling or planks, concrete wall, stone wall, painted brick or whitewashed brick, a wallpaper-like or stucco texture.
- **Floors, about 5:** e.g. herringbone or parquet wood, ceramic tiles, carpet, terracotta / stone tiles, dark wood.
- **Paint colours, about 4** (no texture): e.g. warm white, terracotta, charcoal, dusty blue.
- **Source:** Poly Haven only (CC0). Query `https://api.polyhaven.com/assets?t=textures&c=<category>` and `https://api.polyhaven.com/files/<id>` (send a User-Agent header). Use the `Diffuse` 1k JPG.
- **Budget:** keep the total new assets under 6 MB.
- **Tiling:** pick a sensible `tile` per texture, looking up the asset's real-world dimensions in the API's info if available. Order each list from common to bold.

## Constraints

- Keep the synchronous texture loading exactly as it is: the async `TextureResource` init crashes RealityKit.
- Edit only `Finishes.swift` and `Resources/DemoData/Finishes/`.
- Never commit downloads other than the final JPGs.

## Acceptance

- Build passes.
- A Simulator screenshot of the demo room shows each new wall and floor finish applied at least once. To do that without UI taps, temporarily set `wallFinish`/`floorFinish` in the simulator app's `Library/Application Support/library.json` and relaunch with `-demo`. Check that tiling scale looks right: bricks about 6 cm tall, tiles believable.
- Record the list of added ids in this spec's "As built" section.

## As built

New JPGs total about 3.1 MB (1k Diffuse, `sips` quality 75). `tile` comes from Poly Haven `dimensions` (mm) and was checked in the Simulator: whitewashed brick rows are about 7 cm, terracotta tiles about 26 cm, ceramic diagonals about 45 cm.

- **Walls:** `stucco` (white_stucco, 2), `panelling` (white_planks_clean, 1.8), `white-tile` (long_white_tiles, 1.27; a vertical finger tile, since Poly Haven has no true subway tile), `whitewashed-brick` (whitewashed_brick, 2), `concrete-wall` (concrete_wall_004, 2), `stone` (rustic_stone_wall, 1.52).
- **Paints:** `warm-white`, `dusty-blue`, `terracotta`, `charcoal`.
- **Floors:** `herringbone` (herringbone_parquet, 3.4), `carpet` (poly_wool_herringbone, 0.6; a wool weave used as a carpet), `ceramic` (interior_tiles, 1.9), `terracotta-tile` (terracotta_floor_tiles, 2.08), `dark-wood` (dark_wooden_planks, 2).
- Both lists are reordered from common to bold. Existing ids are unchanged, and `walls[0]`/`floors[0]` are still the defaults.
