# Handoff — A (Alex): room scan, object scan, demo assets

Read `docs/PLAN.md` first. You own scanning, which only works on LiDAR hardware, and you hold the demo device (iPhone 17 Pro).

Teammates: **B** owns Designer/visuals/Home/AR and the shared models; **C** owns backend, networking, render and vibe.

## Files you own

- `RoomVibe/Features/RoomScan/`, `RoomVibe/Features/ObjectScan/`
- `RoomVibe/Core/Capabilities.swift`
- `RoomVibe/Resources/DemoData/`
- `project.yml` (build settings, Info.plist keys) — regenerate with `xcodegen generate` and commit the `.xcodeproj` change

## Current state

- Room scan: `RoomScanner` (delegate) + `RoomCaptureRepresentable`; on result → name alert → `store.addRoom` writes
  `room.json` (`RoomModel`), `captured.json` (raw `CapturedRoom`), `room.usdz`. Not yet run on device.
- Object scan: `ObjectScanModel` drives `ObjectCaptureSession` states (ready → detecting → capturing → completed), then
  `PhotogrammetrySession` → `Objects/<id>/model.usdz`, deletes the photos after. Not yet run on device.

## Status (Oct 17)

- **Done:** tasks 1–3. The room scan and object scan work on device, and a real scanned chair was placed in a real scanned room.
- **Also done:**
  - Designer navigation.
  - Realistic furniture from RoomPlan attributes.
  - The Add Item catalog.
  - Replace and Hide for scanned furniture.
- **Next:**
  - Task 5: rescan the final demo room in good light, pull it with `scripts/pull_demo_assets.py`, and bundle it.
  - "Replace with scan" for the demo chair, so it stands where RoomPlan saw a chair.
  - The demo rehearsal in `docs/DEMO.md`.

## Tasks, in order

1. **Room scan on device (H0–8).** Scan a real room; confirm it saves, reopens after killing the app, and renders correctly in the Designer
   (walls aligned, furniture in the right place, floor at y = 0). Fix the RoomPlan → `RoomModel` conversion if not.
   Consider showing Apple's processed preview before the name prompt, and handling `captureView(didPresent:error:)` failures.
2. **Object scan on device (H4–12).** Compare against Apple's "Scanning objects using Object Capture" sample and adopt what is missing:
   feedback messages, scan-pass flow (`userCompletedScanPass`, flip object), `startDetecting` bounding-box adjust,
   reconstruction progress, and what happens if the app is backgrounded. Store a thumbnail (`Objects/<id>/thumb.jpg`) and
   tell B so the library can show it (additive optional field on `ScannedObject`; B owns `Models.swift`).
3. **Checkpoint 1 (H12):** real scanned chair placed in real scanned room.
4. **Quality + robustness (H12–20).** Practice scans of the demo chair (matte, well lit, walk slowly). Cancel/retry paths;
   delete partial files on failure; low-light warnings.
5. **Demo assets (H20–24).** Export the final demo room (`room.json`) and chair (`model.usdz`) and bundle them as demo data:
   update `ProjectStore.loadDemoData()` with B (B owns that file) to load the bundled USDZ instead of the procedural chair.
   Provide generic furniture USDZ files for B's Tier 2 swap (check licensing).
6. **Hardening (H24–34).** Help C test vibe; add `NSPhotoLibraryAddUsageDescription` to `project.yml` when C asks.
7. **Demo (H34–48).** Write the final demo script, record a full backup video, rehearse 3+ times. Freeze at H40.
