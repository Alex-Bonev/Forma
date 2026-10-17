# Handoff — Teammate C: backend, AI render, vibe mode

Paste this into Claude Code from the repo root. Read `docs/PLAN.md` first; it has the full product, timeline and rules.

## Who you are on the team

You own everything **AI**: the FastAPI backend, the app's networking, capturing a snapshot of the 3D scene, the
"Make it real" photoreal render screen, and vibe mode. None of your work needs LiDAR: use the Simulator or any iPhone with
the `-demo` launch argument.

Teammates (do not do their work):

- **A (Alex):** room scanning and object scanning, demo assets, `project.yml`.
- **B:** Designer 3D view and gestures, room visuals, Home screen, app icon, AR view, shared models.

## Files you own

- `backend/` (everything)
- `RoomVibe/Core/Networking/` (create): `APIClient.swift`
- `RoomVibe/Features/Render/` (create): `Snapshot.swift`, `RenderView.swift`, before/after slider
- `RoomVibe/Features/Vibe/` (create): `VibeView.swift`, product cards

Do not edit `DesignerView.swift`; B adds the button that opens your screen (see "Contract with B").

## Setup

```sh
git clone https://github.com/Alex-Bonev/RoomVibe.git && cd RoomVibe
cp Config/Local.xcconfig.example Config/Local.xcconfig   # your team ID + unique bundle prefix
cd backend && python3 -m venv .venv && .venv/bin/pip install -r requirements.txt pytest
.venv/bin/pytest -q
MOCK=1 .venv/bin/fastapi dev main.py                     # http://127.0.0.1:8000/docs
```

Branches `c/<topic>`; small PRs to `main`.

## Backend today (`backend/main.py`)

- `GET /health` → `{ok, mock}`
- `POST /render` multipart `image`, `prompt`, optional `style_ref` → `{image_base64}` (mock echoes the input)
- `POST /vibe/analyze` multipart `image` → `Style` JSON (`style_name, palette, materials, furniture_types, decor_items, search_queries`)
- `POST /vibe/products` JSON `Style` → `{products: [{title, price, image_url, product_url, retailer}]}`
- `X-App-Secret` header checked against `APP_SHARED_SECRET` when set. Uploads capped at 4 MB (Vercel limit is 4.5 MB).
- `MOCK=1` (default) returns canned data. Non-mock endpoints return 501 until you wire a provider.

## Contract with B (agree names in chat before coding)

- You provide `func captureDesignerSnapshot() -> UIImage?` in `Features/Render/Snapshot.swift`.
  Approach to try first: render the key window with `UIGraphicsImageRenderer` + `drawHierarchy(in:afterScreenUpdates: true)`
  and verify on device that the RealityKit (Metal) content is captured, not a blank area. `// VERIFY:` until confirmed.
  If blank, fall back to an offscreen `RealityRenderer` or ask B to expose the scene entity + camera transform.
- You provide `struct RenderView: View { init(snapshot: UIImage) }`. B presents it from a "Make it real ✨" button.

## Tasks, in order

1. **Pick providers (H0–2).** Image model for `/render` must keep the room layout: image-to-image editing or
   structure/depth-conditioned generation. Check current model names, pricing, size limits and endpoints in the provider docs
   today; do not rely on memory. Ask the team about sponsor credits. Write the decision in `docs/PLAN.md` §8.
2. **Real `/render` (H2–8).** Add the provider call with `httpx` (90 s timeout). Return a URL or a compressed JPEG, never a raw
   multi-MB PNG. Keep `MOCK=1` working. Extend `test_main.py` only with what breaks if logic breaks.
   Deploy to Vercel (`vercel` preview, `vercel --prod`), set env vars there, share the URL + secret with the team outside git.
3. **App networking (H8–12).** `APIClient` with `URLSession` (no dependencies): base URL + secret from build settings or a
   gitignored config, not hardcoded keys. JPEG at ≤1536 px long edge, quality 0.8. Clear errors.
4. **Render screen (H8–20).** `Snapshot.swift`, `RenderView`: loading state, before/after slider (drag divider), save to Photos
   (`NSPhotoLibraryAddUsageDescription` — ask A to add it to `project.yml`), retry on error, cache last result per room.
5. **End to end on device (H20–24).** With B's button merged: Designer → Make it real → render from deployed backend.
6. **Vibe mode (H24–34).** Backend: vision LLM returns strict JSON validated by the `Style` model; product search API returns
   up to 8 deduped products. App: `VibeView` — pick inspiration image (`PhotosPicker`) → restyled render (reuse `/render` with the
   style description) + product cards with "Open" links. Build the UI against `MOCK=1` first.
7. **Demo safety (H34–40).** Pre-generate renders for the demo room/angle and bundle or cache them so the demo works offline.
   Document "hit `/health` before going on stage".
8. **Freeze at H40.** Bug fixes only; join demo rehearsals.

## Acceptance checks

- `pytest` passes; `MOCK=1` works without any keys.
- Render returns in < 60 s typical, under 4.5 MB both ways.
- App shows a friendly error + retry when offline, and a cached result if one exists.
- No API key anywhere in the iOS target or in git.
