# Spec: Scan intelligence (on-device classification)

Status: **ready to build**. Owner: A (Alex), built by a delegated agent. Branch base: `a/realism`.

## Why Apple Vision, not Jev

Jev (TypeSafe AI) is a proprietary, early-access, **text-only** classifier: it takes strings or JSON, not images, and it runs only through a cloud API. Our inputs are camera photos, and the demo must work offline.

Apple Vision's `VNClassifyImageRequest` runs on device, is free, works offline, and has 1,303 labels. Tested on our textures:
- **Brick:** `brick` 0.96.
- **Wood floors:** `wood_processed` 0.21–0.66.
- **Plaster and marble:** nothing confident.
- **Object labels it has:** `trash_can`, `decorative_plant`, `plant`, `lamp`, `textile`, `kitchen_sink`, `toilet_seat`, …
- **Traffic cone:** no label.

Richer answers (style, exact product) belong to David's backend vision LLM, not to this spec.

## Goals

1. **Suggest what a marked item is.** When the user taps to mark something during a room scan:
   - Classify the camera image around the tap.
   - In the Designer, the marked item offers a one-tap "Use <Catalog item>".
2. **Pick wall and floor finishes from the scan photos.**
   - Walls that look like brick get the Brick preset; otherwise keep the matched paint color (already built).
   - Floors that look like wood get Oak.

## Existing pieces (read first)

- `RoomScanView.swift`:
  - `RoomScanner.mark(at:)` raycasts into `view.captureSession.arSession` and appends a marker point.
  - `save()` builds `RoomModel(room)` plus `RoomModel.markedItems(...)`, applies `.axisAligned()`, and sets `wallFinish` from `RoomPhotos.wallColor`.
- `RoomPhotos.swift` and `RoomPhotoMath.swift`:
  - Captured shots hold a JPEG, 320 px RGBA `PhotoPixels`, and a `RoomPhoto` (intrinsics, camera transform, image size).
  - The wall projection math lives here (pure functions).
- `RoomAlignment.swift`: `markedItems` builds `RoomModel.Box(label: "marked item")`. `Box.attributes: [String]?` exists and is free-form.
- `Finishes.swift`: preset ids are walls `white|plaster|beige|brick|sage|navy` and floors `light|oak|planks|marble|concrete`. Project fields are `wallFinish` and `floorFinish`.
- `Catalog.swift`: `CatalogItem.all` (ids such as `trash`, `plant`, `floor_lamp`, `rug`, `chair`, `box`, `side_table`, `custom_box`, …).
- `DesignerView.swift`: the panel for a selected room object is the `if let i = selectedRoomObject …` block. `replaceRoomObject(_:catalog:)` already fits a catalog item to the box and keeps its height.

## Requirements

1. **New file `RoomVibe/Features/RoomScan/SceneClassifier.swift`:**
   - `nonisolated` pure helpers around `VNClassifyImageRequest`, run off the main thread.
   - `classify(_ image: CGImage, crop: CGRect?) -> [(String, Float)]`.
   - A mapping table from Vision identifiers to `CatalogItem.id`, with a confidence threshold of about 0.3. Choose the mapping from `supportedIdentifiers()`.
2. **Marked items:**
   - In `mark(at:)`, after a successful hit, crop the camera image around the tap: a square of about 35% of the short side, converted to image coordinates with the inverse of the display transform already used there.
   - Classify it asynchronously, and keep `(point, suggestion)` with the marker.
   - On save, write the suggestion into that marked box's `attributes` as `"Vision.<identifier>"` and `"Suggest.<catalogId>"`.
3. **Finishes:**
   - At save, for each photo, crop the projected bounding box of each wall that faces the camera (reuse the projection math) and classify it.
   - Brick wins if at least 30% of classified wall crops report `brick` ≥ 0.5.
   - Floor: classify the projected floor region (or the bottom third of photos pitched downward). Wood (`wood_processed`/`wood_natural` ≥ 0.3 in ≥ 30% of crops) sets `floorFinish = "oak"`.
   - Otherwise keep the existing paint and light floor.
   - Work at ≤ 512 px. All 40 photos must finish in < 1.5 s on device, off main.
4. **Designer** (edit only the marked-item panel):
   - When the selected box has a `Suggest.<id>`, show "Looks like a <Name>" with a prominent "Use <Name>" button that calls `replaceRoomObject(i, catalog:)`.
   - Keep the Replace menu as it is.
5. **Check:**
   - One runnable self-check of the mapping and vote logic (pure code, `scripts/scene_check/main.swift`).
   - Run the Vision classifier on the bundled textures (`Resources/DemoData/Finishes/*.jpg`): brick → Brick; `finish_wood_floor.jpg` → wood.

## Acceptance

- Builds with no new warnings.
- Self-check passes.
- The existing UI tests pass (`xcodebuild test -scheme RoomVibe`).
- Nothing touches the network.
- Unverified on-device behavior is marked `// VERIFY on device`.

## As built (scan-intel branch)

Changes from the requirements above, and why:
- **Suggestion threshold is 0.25, not 0.3.** Floor lamps scored 0.28 and 0.34 on the Mac. A wrong guess costs one ignorable button.
- **Only the centered square of each crop is classified.** On a Mac M5, a 1:2 input took 19 ms and a square took 6.6 ms, so Vision appears to tile non-square inputs. Wall boxes and the floor's bottom third are therefore sampled at their middle.
- **Finish classification has a 1.2 s deadline.** Photos are visited even-then-odd, so a run cut short on a slow device still covers the whole room.
- **Wall crops** use the wall's middle, inset 15% horizontally and 20% vertically as in `wallRGB`. A wall is skipped when a corner is behind the camera or when it covers under 10% of the frame. There is no occlusion test.
- **Floor** uses the bottom third of photos pitched more than ~20° down. The "bottom" follows image orientation, which comes from gravity in the camera frame (portrait = `.right`).
- **Self-check** (`scripts/scene_check/main.swift`) also runs Vision on the bundled textures and runs `finishes()` end to end on 40 brick photos (timing).

### Mapping (Vision identifier → `CatalogItem.id`)

Scores are from Mac runs (`VNClassifyImageRequest`, macOS 26, M5) on CC0 Wikimedia Commons photos, 4 per query. Each line gives the score of the mapped label, or the image's top label when it missed.

| Vision | Catalog | Evidence |
|---|---|---|
| `trash_can` | trash | 0.88, 0.89, 0.61; 1 miss (photo was mostly a car) |
| `plant`, `decorative_plant` | plant | 0.79, 0.33, 0.85, 0.42 |
| `lamp` | floor_lamp | 0.28, 0.34; 2 misses (sculptural lamps read as `statue`) |
| `sofa` | sofa | 0.82, 0.65, plus `chair` 0.69 on a third sofa photo |
| `chair`, `folding_chair`, `chair_other` | chair | 0.46, 0.44, 0.40, 0.97 |
| `swivel_chair` | desk_chair | not tested |
| `stool`, `table` | side_table | `stool` 0.60 on 1 of 4; side-table photos read as chair/stool ~0.2 |
| `bench` | bench | 0.90, 0.82, 0.90, 0.95 |
| `television`, `computer_monitor` | tv | 0.82, 0.44, 0.70; 1 read as `cabinet` 0.32 |
| `bookshelf` | bookshelf | 0.74 (on a "desk" photo of shelving) |
| `cabinet` | cabinet | 0.14, 0.28, 0.14 (mostly under the threshold); desks also read as `cabinet` ~0.7 |
| `desk` | desk | never fired on 4 desk photos |
| `bed` | bed | 0.70 on 1 of 4 |
| `cardboard_box`, `carton`, `crate`, `basket_container`, `luggage` | box | box 0.18, 0.10, 0.31, 0.73; luggage 0.24 |

Left out:
- `armchair`: it equals `chair` on every chair photo.
- `textile`: 0.40–0.66 on boxes, beds and suitcases, so it is no evidence of a rug.
- Traffic cones: nothing fired (top label `bell` 0.43), as expected.

Textures (512 px):

| Texture | Result |
|---|---|
| brick | `brick` 0.96 → Brick |
| `finish_wood_floor` | `wood_processed` 0.69 → Oak |
| plank flooring | 0.23 (under 0.3 full-frame; 0.71 as a center crop) |
| plaster, beige, marble, concrete | nothing above 0.2 |
