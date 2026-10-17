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
