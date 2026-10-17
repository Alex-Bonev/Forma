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
