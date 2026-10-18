# RoomVibe — Team Plan (48h)

Source of truth for scope, ownership and timeline. Per-person handoff prompts live next to this file:

- `docs/handoff-A-scanning.md` — **Alex** (Mac + LiDAR iPhone 17 Pro, the demo device)
- `docs/handoff-B-designer.md` — **Michelle (B)** (Mac + LiDAR iPhone)
- `docs/handoff-C-backend-ai.md` — **David (C)** (Mac, no LiDAR needed)

## 1. Product

iPhone app (LiDAR) that lets a user:

1. **Scan a room** → interactive 3D "dollhouse" of the room with furniture as labeled blocks.
2. **Scan a real object** (e.g. a chair in a store) → textured, real-scale 3D model.
3. **Place the object in the room** → drag/rotate it to see if it fits.
4. **Make it real** (stretch #1) → snapshot of the 3D scene → AI image model → photoreal render, before/after slider.
5. **Vibe mode** (stretch #2) → inspiration image → restyled render + shoppable product links.
6. **View in AR** (stretch #3, only if time) → place the scanned chair in the live camera feed.

Hackathon demo, ~3 minutes, live. Optimize for a reliable demo, not production robustness. No accounts, no App Store.

## 2. Decisions (locked)

| Topic | Decision |
|---|---|
| Platform | Native iOS 18+, Swift + SwiftUI, RealityKit, RoomPlan, Object Capture. No third-party iOS deps. |
| Demo device | Alex's iPhone 17 Pro (iOS 26.6). Backup: Teammate B's LiDAR phone. |
| Room rendering | Built by us (`RoomBuilder`) from our own `RoomModel` JSON, not the exported USDZ. |
| Camera / gestures | Custom orbit camera in `DesignerView` (Apple's `.realityViewCameraControls` swallowed object drags and allowed zooming through walls). |
| Storage | On-device: `Application Support/library.json` index + `Projects/<id>/`, `Objects/<id>/` folders. |
| Backend | Python FastAPI on Vercel, stateless, `MOCK=1` default. Holds all API keys. 4.5 MB body cap. |
| Stretch order | 1) Photoreal render, 2) Vibe mode, 3) AR view. |
| Timeline | 48h. Feature freeze at **H40**. |

## 3. What exists today (`main`, plus `a/polish` in review)

- **Home:** room list and object library, rename and delete (swipe or long-press), Scan Room and Scan Object
  (disabled without LiDAR), "Load Demo Data".
- **Room scan:** RoomPlan, with a review step before saving.
  - Saves are aligned so the longest wall runs along X; floor outline and RoomPlan attributes are kept.
  - Tap-to-mark items RoomPlan misses; Apple Vision suggests what they are.
  - ~40 photos captured during the scan (gallery, Matched Paint wall colour, Brick/Oak detection).
- **Object scan:** Object Capture with passes and flip, then on-device reconstruction to `model.usdz` + `thumb.jpg`.
  Scan Real replaces a selected placeholder in place.
- **Designer:**
  - Own orbit camera + UIKit touch layer: drag objects or orbit, two-finger pan, pinch, twist, tap select.
  - Walls between the camera and the room fade out. Reset / Room Photos / Finishes / Cutaway controls. Tap the title to rename the room.
  - Selection: blue corner brackets + floor disc, one card with ≤4 labeled actions. Undo for Delete / Hide.
  - Drags stay inside the scanned floor outline.
- **Furniture:** Poly Haven photoreal models (toggle) → rounded procedural models → Kenney, fitted to RoomPlan's boxes.
  22-item catalog incl. Custom Box. Replace / Size (incl. mounting height) / Hide scanned furniture.
- **Finishes:** 12 wall presets + Matched Paint, 10 floors (CC0 Poly Haven).
- **Tests:** 8 UI tests in `RoomVibeUITests`, self-checks in `scripts/*_check`, `backend/test_main.py`.
- **Backend** (David, `c/backend-ai`): real providers, APIClient, Render and Vibe screens. Not merged yet, and no
  button opens them yet (B's "Make it real" button, §4 touch points).

**Specs for in-flight and recent work** (agents build against these; update them whenever scope changes):
- [`docs/specs/designer-editing.md`](specs/designer-editing.md): select / edit size + mounting height / Custom Box / replace / scan-to-replace (built).
- [`docs/specs/rounded-furniture.md`](specs/rounded-furniture.md): one soft, rounded style; procedural models for every low-poly category.
- [`docs/specs/scan-intelligence.md`](specs/scan-intelligence.md): on-device Apple Vision classification for marked items and wall/floor finishes.
  We chose Vision over Jev because Jev is text-only, cloud-only and early-access.

**Scope changes (Oct 17, Alex):**
- Removed: the top-view toggle.
- Added:
  - photos captured during room scans (gallery + Matched Paint wall color)
  - wall/floor finishes
  - tap-to-mark missed items during a scan
  - editable size and mounting height
  - scan-to-replace placeholders
  - a consistent rounded furniture style

RoomPlan facts that matter (checked in the SDK and on a real scan):
- **Detection:** only 16 object categories are detected (storage, refrigerator, stove, bed, sink, washerDryer,
  toilet, bathtub, oven, dishwasher, table, sofa, chair, fireplace, television, stairs). Anything else, such as a
  traffic cone, is never detected. Use Add Item or Object Capture instead.
- **Facing:** objects face local +Z, with their back toward −Z (against the wall).

## 4. Ownership (no overlap)

Every file has exactly one owner. To change someone else's file: ask in chat, or open a PR and tag them.

| Area | Owner | Files / folders |
|---|---|---|
| Room scan, object scan, capability checks, demo assets | **A (Alex)** | `Features/RoomScan/`, `Features/ObjectScan/`, `Core/Capabilities.swift`, `Resources/DemoData/`, `project.yml`, `scripts/` |
| Designer navigation + furniture realism (moved from B at Alex's request) | **A (Alex)** | `Features/Designer/{TouchSurface,OrbitCamera,Catalog}.swift`; in `DesignerView.swift` the touch handlers, picking, catalog/replace/hide; in `RoomBuilder.swift` `furnitureModel`/`furnish`; `RoomVibeUITests/` |
| Room visuals (walls, floor, materials, labels), Home UI, app icon, AR view | **Michelle (B)** | rest of `Features/Designer/` (`RoomBuilder.build` surfaces/floor/materials, `WallCutaway` look), `Features/Home/`, `Features/AR/` (new), `Assets.xcassets` (new) |
| Backend, app networking, render + vibe screens, snapshot capture | **David (C)** | `backend/`, `Core/Networking/` (new), `Features/Render/` (new), `Features/Vibe/` (new) |
| Shared data layer (additive optional fields only) | **Michelle (B)** (reviewer: A) | `Core/Models.swift`, `Core/ProjectStore.swift`, `App/RoomVibeApp.swift` |
| Docs | everyone (own sections) | `README.md`, `docs/` |

Known touch points (pre-agreed, small):

- **A ↔ B:** `RoomModel` format. A fills it from `CapturedRoom`; B renders it. Add fields only (never rename/remove) so old saved rooms still decode — make new fields optional.
- **B ↔ C:** B adds one "Make it real ✨" toolbar button in `DesignerView` that presents C's `RenderView(snapshot: UIImage)`.
  C owns snapshot capture (`Features/Render/Snapshot.swift`, `func captureDesignerSnapshot() -> UIImage?`). B calls it.
  Until C's view exists, B wires the button to a placeholder sheet.
- **A ↔ C:** none expected.

## 5. Git workflow

- `main` must always build and run. Small PRs, merge several times a day. No long-lived branches.
- Branch names: `a/<topic>`, `b/<topic>`, `c/<topic>`.
- Xcode uses folder-synced groups: adding `.swift` files does **not** touch `project.pbxproj`. If you must change build settings,
  edit `project.yml` and run `xcodegen generate` (A merges these).
- Signing lives in your own gitignored `Config/Local.xcconfig`. Never commit team IDs.
- Before pushing: build for device (`⌘B` with your phone selected). Nobody merges a red build.

## 6. Timeline (H0 = start of build)

| When | A — Scanning | B — Designer / polish | C — Backend / AI |
|---|---|---|---|
| H0–2 | App on phone. First real room scan. | App on phone. Verify drag/zoom/rotate on device. | Backend running locally. Pick image provider (see §8). |
| H2–8 | Room scan end to end; fix anything RoomPlan-specific. Start object scan. | Gesture polish, selection highlight, undo for delete. | Real `/render` with chosen provider. Deploy to Vercel. |
| H8–12 | Object scan end to end (capture → reconstruct → library). | Room visuals: floor from real outline, better wall look, shadows. | `APIClient` in app; `Snapshot.swift`; `RenderView` with mocked backend. |
| **H12** | **Checkpoint 1: real scanned chair placed in real scanned room on Alex's phone.** | | |
| H12–20 | Scan quality: progress UI, failure retries, thumbnails. Practice scans of demo chair. | Tier 2: swap furniture boxes for generic USDZ models scaled to boxes (A provides models). | Before/after slider, save to Photos, result caching, error + retry UI. |
| H20–24 | Capture **final demo assets** (room + chair) and bundle them as demo data. | App icon, launch look, empty states, transitions. | Render end to end on device against Vercel. |
| **H24** | **Checkpoint 2: "Make it real" works on device; demo data = our real scans.** | | |
| H24–34 | Scanning hardening: low light, cancel/resume, storage cleanup. Help C test vibe. | AR view (stretch #3) if render is solid. | Vibe mode: `/vibe/analyze`, `/vibe/products`, `VibeView` with product cards. |
| H34–40 | Write demo script, record backup video of full run. | Polish pass on everything visible in the demo. | Pre-generate and cache AI results for the demo room as fallback. |
| **H40** | **Feature freeze.** Bug fixes only. Rehearse the demo at least 3 times. | | |
| H40–48 | Rehearse; fix demo blockers only. Warm `/health` before stage. | | |

If behind at H24: drop vibe mode and AR. Render + core is the demo.

## 7. Demo script (3 min)

1. Open app → previously scanned room in dollhouse view. Orbit. "My living room, scanned in 30 seconds with LiDAR."
2. Quick live room scan of the stage area (~20 s) to prove it's real. Skip if the venue is chaotic.
3. Object library → chair scanned "at the store" (pre-scanned). Show the capture flow for a few seconds only; never wait on reconstruction live.
4. Drop chair into room, drag next to the sofa, twist to rotate. "Does it fit? Now we know."
5. "Make it real ✨" → before/after photoreal render.
6. (If built) Vibe image → restyled room + products.

Fallbacks: bundled demo data if a scan fails; cached render if Wi-Fi fails; screen recording as last resort.

## 8. Open questions

| # | Question | Who decides | Needed by |
|---|---|---|---|
| 1 | Teammates' GitHub usernames (to add as collaborators) | Alex | Now |
| 2 | ~~Which teammate is B and which is C?~~ Michelle = B, David = C | — | done |
| 3 | Image provider for `/render`: needs image-to-image or structure-conditioned editing (keeps layout). Any sponsor credits? | C, confirm with team | H2 |
| 4 | LLM for vibe analysis and shopping/product search API | C | H24 |
| 5 | Who owns the Vercel account + where keys are shared (not in git) | C | H6 |
| 6 | Judging criteria / required sponsor tech that should be visible in the demo | Alex | H2 |
| 7 | App name/branding final? ("RoomVibe" assumed) | Team | H20 |
| 8 | Venue Wi-Fi reliability — decides how much we lean on cached AI results | Alex | H34 |

C's proposals (not yet confirmed by the team):

- **#3:** Gemini image editing (Interactions API), `IMAGE_MODEL=gemini-nano-banana-2.1` (~$0.034/image at 1K, no free tier).
  Check current pricing on the provider page before relying on it.
- **#4:** Claude (`claude-opus-5-5`, structured output) for vibe analysis, SerpAPI Google Shopping for products.
- **#5:** still open. C deploys from `backend/`; provider keys live only in Vercel env vars.

## 9. Rules for Claude Code sessions (all three of us)

- Read `docs/PLAN.md` and your own handoff file first. Stay inside your owned files.
- Check current Apple docs / SDK headers before using an API. If uncertain, leave a `// VERIFY:` comment.
- Keep views thin; logic in `@Observable` classes. Match the style of surrounding code.
- Every feature degrades gracefully: no LiDAR → demo data; no network → mock/cached results.
- Never put API keys in the app.
- Scanning cannot be tested in Simulator. Everything else should run in Simulator with `-demo`.
