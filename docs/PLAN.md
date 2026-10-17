# RoomVibe — Team Plan (48h)

Source of truth for scope, ownership and timeline. Per-person handoff prompts live next to this file:

- `docs/handoff-A-scanning.md` — **Alex** (Mac + LiDAR iPhone 17 Pro, the demo device)
- `docs/handoff-B-designer.md` — **Teammate B** (Mac + LiDAR iPhone)
- `docs/handoff-C-backend-ai.md` — **Teammate C** (Mac, no LiDAR needed)

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

## 3. What exists today (commit `5a2db11`)

- Home: room list, object library, Scan Room / Scan Object (disabled without LiDAR), "Load Demo Data".
- Room scan: `RoomCaptureView` → `RoomModel` + `captured.json` + `room.usdz`. **Compiles; not yet run on device.**
- Object scan: `ObjectCaptureView` guided flow → `PhotogrammetrySession` → `model.usdz`. **Compiles; not yet run on device.**
- Designer: dollhouse with category-colored rounded boxes + billboard labels, cutaway-walls toggle, room dimensions,
  object tray, drag on floor, twist/buttons to rotate, delete, persisted placements.
  Custom orbit/zoom camera **just landed, needs on-device check**.
- Demo data: hand-made 5×4 m room + procedural chair (works on Simulator / any iPhone).
- Backend: `/health`, `/render`, `/vibe/analyze`, `/vibe/products` in MOCK mode, shared-secret header, size cap, one test.

## 4. Ownership (no overlap)

Every file has exactly one owner. To change someone else's file: ask in chat, or open a PR and tag them.

| Area | Owner | Files / folders |
|---|---|---|
| Room scan, object scan, capability checks, demo assets | **A (Alex)** | `Features/RoomScan/`, `Features/ObjectScan/`, `Core/Capabilities.swift`, `Resources/DemoData/`, `project.yml` |
| Room rendering, Designer interaction, Home UI, visual polish, app icon, AR view | **B** | `Features/Designer/`, `Features/Home/`, `Features/AR/` (new), `Assets.xcassets` (new) |
| Backend, app networking, render + vibe screens, snapshot capture | **C** | `backend/`, `Core/Networking/` (new), `Features/Render/` (new), `Features/Vibe/` (new) |
| Shared data layer | **B** (reviewer: A) | `Core/Models.swift`, `Core/ProjectStore.swift`, `App/RoomVibeApp.swift` |
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
| 2 | Which teammate is B (has LiDAR) and which is C? | Team | H0 |
| 3 | Image provider for `/render`: needs image-to-image or structure-conditioned editing (keeps layout). Any sponsor credits? | C, confirm with team | H2 |
| 4 | LLM for vibe analysis and shopping/product search API | C | H24 |
| 5 | Who owns the Vercel account + where keys are shared (not in git) | C | H6 |
| 6 | Judging criteria / required sponsor tech that should be visible in the demo | Alex | H2 |
| 7 | App name/branding final? ("RoomVibe" assumed) | Team | H20 |
| 8 | Venue Wi-Fi reliability — decides how much we lean on cached AI results | Alex | H34 |

## 9. Rules for Claude Code sessions (all three of us)

- Read `docs/PLAN.md` and your own handoff file first. Stay inside your owned files.
- Check current Apple docs / SDK headers before using an API. If uncertain, leave a `// VERIFY:` comment.
- Keep views thin; logic in `@Observable` classes. Match the style of surrounding code.
- Every feature degrades gracefully: no LiDAR → demo data; no network → mock/cached results.
- Never put API keys in the app.
- Scanning cannot be tested in Simulator. Everything else should run in Simulator with `-demo`.
