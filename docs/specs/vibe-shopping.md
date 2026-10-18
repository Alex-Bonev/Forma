# Spec: Vibe shopping (vibe → browser agents → items in the room)

Status: **draft**. Owner: C (David). Branch base: `main`, branch `c/vibe-shopping`.

## Pipeline

1. **Gauge the vibe.** The user gives an inspiration photo, a text prompt ("cozy reading nook, warm wood, under $800"), or both. A vision LLM returns a `Style` plus a shopping list and an optional budget.
2. **Shop with browser agents.** One Browser Use cloud agent per shopping-list item browses real retailers and returns real, in-stock products with price, image, link and dimensions. Any online store is allowed **except Facebook Marketplace**.
3. **Respect the budget.** If the user gives a budget, the chosen set of products never exceeds it.
4. **Put items in the room.**
   - **Core:** each product becomes a catalog box (the closest `CatalogItem`, resized to the product's real dimensions) that links back to the product.
   - **Reach:** the product photo goes through Meta's SAM 3D Objects to produce a real 3D model, which replaces the box.

## Why these providers

- **Browser Use Cloud, API V4** (`POST https://api.browser-use.com/api/v4/runs`, header `X-Browser-Use-API-Key`). Docs say V4 is the API for new integrations and V2 is legacy. A run takes `task`, `outputSchema` (JSON Schema, parsed result in `run.output`) and `maxCostUsd`. Runs take minutes, so the backend never waits on one inside a request (see "Async jobs").
  - V4's `allowedDomains` scopes **secrets**, not navigation. The Facebook Marketplace ban is enforced by the task prompt **and** by a backend URL filter.
  - Free tier: 10 concurrent browsers. We need at most 6 at a time.
- **SAM 3D Objects via fal** (`fal-ai/sam-3/3d-objects`, `FAL_KEY`). Takes `image_url` plus an optional `prompt` for auto-segmentation (for example "armchair") and `export_textured_glb`. Returns `model_glb`, `gaussian_splat` and per-object `metadata`. The weights are open (Meta), but self-hosting needs a large GPU, so a hosted endpoint is the hackathon choice.
- SerpAPI (`/vibe/products`) stays as the fast fallback when agents fail or the demo is offline.

Check field names against the provider docs on the day you build. These were read on 2026-10-17.

## Existing pieces (read first)

- `backend/main.py`:
  - `Style`, `Product`, `/vibe/analyze` (image only, Claude structured output), `/vibe/products` (SerpAPI).
  - `MOCK=1` canned responses, `check_secret`, `require(key, name)`.
  - Upload cap is 4 MB; Vercel caps bodies at 4.5 MB.
- `backend/test_main.py`: mock-transport tests.
- `RoomVibe/Core/Networking/APIClient.swift`: `analyzeVibe(_:)`, `products(for:)`, multipart `addField`/`addImage`.
- `RoomVibe/Features/Vibe/VibeView.swift`: `VibeView` and `VibeModel`. It already does photo pick → analyze → render + products, with a `ProductCard` that has an Open link.
- `RoomVibe/Core/Models.swift` (owned by B):
  - `Placement` has `catalogItem`, `scale`, `fitScale`.
  - `ScannedObject.modelFile` points at `Objects/<id>/model.usdz`.
- `RoomVibe/Features/Designer/Catalog.swift`: `CatalogItem.all` (ids and real sizes in meters), `entity()`.
- `RoomVibe/Core/ProjectStore.swift`: stores objects as `Objects/<id>/model.usdz`. The sample chair shows how a USDZ becomes a `ScannedObject`.

## Requirements

### 1. Vibe from image or text (`/vibe/analyze`)

- Multipart with `image` (optional) and `prompt` (optional, ≤ 1000 chars). At least one is required; otherwise return 400.
- Extend `Style` with fields that are optional or defaulted, so the old app and the mocks still decode:
  - `budget_usd: float | None`: only when the user states one ("under $800", "budget 1.2k"). Never invent one.
  - `room_type: str` (for example "living room").
  - `shopping_list: list[ShoppingItem]`, 3–6 items. Each item has `category` (one `CatalogItem.id`, or `"decor"`), `query` (a specific search phrase) and `max_price_usd: float | None` (that item's share of the budget, when a budget exists).
- Keep `search_queries` (SerpAPI fallback), filled from `shopping_list[].query`.
- The prompt tells the model the valid category ids and that budget shares must sum to ≤ `budget_usd`.

### 2. Shopping agents (async jobs)

- `POST /vibe/shop` with JSON `{style, budget_usd?}`:
  - Starts one Browser Use run per `shopping_list` item (max 6).
  - Returns `{job: "<token>", items: [{category, query}]}` right away (< 5 s).
  - The token is the run ids, base64url-joined. No DB: the backend stays stateless.
- `GET /vibe/shop/{job}`:
  - Reads each run once and returns `{done: bool, items: [{category, status: running|done|failed, products: [Product]}]}`.
  - The app polls every 4 s. Results show up item by item.
- Each run:
  - `task`: a fixed template filled with the vibe (style name, palette, materials) plus the item query and its price cap. It says:
    - Use any online retailer, but never facebook.com or Facebook Marketplace.
    - Do not log in, add to cart or check out.
    - Return 2 in-stock products with the direct product page URL, the main product image URL, the price in USD and the dimensions if listed.
  - `outputSchema`: `AgentResult = {products: [{title, price_usd, image_url, product_url, retailer, width_cm?, depth_cm?, height_cm?}]}`.
  - `maxCostUsd`: from env `BROWSER_USE_MAX_COST` (default 0.50).
  - Model: from env `BROWSER_USE_MODEL`; unset means the provider default.
- Backend validation for every agent product, before returning it:
  - `https` URLs only.
  - Drop any host that is or ends with `facebook.com`, `fb.com` or `fb.me`.
  - `price_usd > 0`.
  - Dedupe by `product_url`.
- Extend `Product` with optional fields: `price_usd: float | None`, `category: str | None`, `dimensions_cm: [w, h, d] | None`. The `price` string stays for display.
- `MOCK=1`:
  - `POST` returns a fixed token.
  - `GET` returns canned products. The first poll reports half the items as still running, so the app's streaming UI can be built offline.
- A run that is `failed` or times out (> 6 min) has its item marked `failed`. The app then offers "Try quick search", which calls `/vibe/products` with that query.

### 3. Budget

- Pure function `pick_within_budget(items, budget) -> chosen`, in `backend/budget.py`:
  - Choose at most one product per item, maximizing items covered and then total vibe fit (agent order), subject to `sum(price_usd) ≤ budget`.
  - Use exact search (≤ 6 items × 2 products) rather than greedy.
- `GET /vibe/shop/{job}` adds `chosen: [product_url]` and `total_usd` when `budget_usd` is set and every item is finished.
- With a budget:
  - Products with no parseable price are never chosen.
  - The app shows the chosen set first, labelled "Fits your $X budget", and shows the total.
  - The UI says prices exclude shipping and tax.
- Without a budget, `chosen` is the first product of each item.

### 4. App: input and results (`VibeView`)

- The input card has a photo picker **and** a text field ("Describe the vibe…"). Either is enough to start, and a budget can be typed in the text.
- After the analysis:
  - Style section (exists).
  - Restyled render (exists).
  - A "Shopping" section with one row per shopping-list item. Each row shows a spinner while running, then product cards, or a failure with "Try quick search".
- `ProductCard` gains an "Add to room" button next to Open. If the product is in `chosen`, it shows a "Fits budget" badge.
- `APIClient`:
  - `analyzeVibe(image: UIImage?, prompt: String?)`.
  - `startShopping(_ style:) -> ShopJob`.
  - `pollShopping(_ job:) -> ShopStatus`.
  - Use `Lossy<>` decoding as `products(for:)` does.

### 5. Items into the room as catalog boxes (core)

- "Add to room" creates a `Placement`:
  - `catalogItem` = the product's `category`, or `"custom_box"` for `"decor"` and unknown categories.
  - Placed at the room's center, which is the scene origin (RoomBuilder centers the room). The Designer clamps it inside the walls, and the user drags it into place. It does not avoid other furniture yet.
  - `scale` set so the model matches `dimensions_cm` when present; otherwise the catalog size.
- New optional field `Placement.product: ShopProduct?` (title, price, product_url, image_url). Old projects decode unchanged.
  - **Models.swift is B's file.** Agree on the field name with B before editing.
- In the Designer's selected-object panel, a placement with `product` shows its title, price and an "Open product" link.
  - **DesignerView.swift is B's file.** B adds this, or approves the diff.

### 6. Real 3D model with SAM 3D (reach)

- `POST /vibe/model3d` with JSON `{image_url, category}`:
  - `image_url` must be https.
  - Submits to the fal queue (`POST https://queue.fal.run/fal-ai/sam-3/3d-objects`, header `Authorization: Key $FAL_KEY`) with `prompt` = the category in words (`"object"` for decor) and `export_textured_glb = true`.
  - Returns `{request_id}`. This is an HMAC-signed token (same pattern as the shopping job) that carries fal's own `status_url` and `response_url` from the submit response, so the backend stays stateless and never guesses fal's URL layout.
- `GET /vibe/model3d/{request_id}` returns `{status: running|done|failed, usdz_base64?, error?}`:
  - Verifies the signature. The key is never empty in production, because `check_secret` refuses every request with `MOCK=0` when `APP_SHARED_SECRET` is unset. Both URLs must be https on `fal.run`/`fal.ai` or a subdomain; otherwise 400.
  - Polls `status_url`. On `COMPLETED` it reads `response_url`, then downloads `model_glb.url`:
    - Allowed CDN hosts are `fal.media`, `fal.run`, `fal.ai` and their subdomains.
    - https only, no redirects, and no API key sent.
    - IP-literal hosts and hosts that resolve to private, loopback or link-local addresses are refused.
    - Residual risk, accepted: DNS rebinding. The check resolves the host separately from httpx's connection, so a host could answer differently the second time. It's accepted because only fal's CDN host names are allowed at all.
    - Size cap ≤ 40 MB (Content-Length checked first).
  - Converts the GLB in a worker thread.
  - Non-JSON or non-object 2xx bodies from fal return 502. A bad key returns 502.
- `MOCK=1`: the POST returns `mock-model`, and the GET returns `done` with a USDZ converted from a generated box.
- trimesh, numpy and the converter are imported only inside these handlers, so the other endpoints' cold start is unchanged.
- **GLB → USDZ: decided, backend converter (`backend/usdz.py`).** RealityKit loads USDZ, not GLB.
  - trimesh reads the GLB. We write the USDA layer as text (UsdPreviewSurface with a UsdUVTexture) and pack it into a USDZ: an uncompressed zip, layer first, each file 64-byte aligned.
  - Passes `usdchecker --arkit`. Loads in RealityKit with correct extents and a textured PBR material.
  - trimesh flips glTF's top-left V origin to bottom-left on load, which is what USD `st` expects.
  - Output is bounded so its base64 fits Vercel's 4.5 MB response cap:
    - Meshes are decimated to ≤ 40,000 faces with `fast_simplification`. UVs are carried through the collapse map.
    - Textures go to ≤ 1024 px JPEG.
    - The face budget halves until the USDZ is ≤ 3.2 MB.
    - Inputs over 1M faces are refused, counting each instanced node, before any geometry is copied.
    - These are refused too:
      - Draco and meshopt-compressed GLBs.
      - External buffer or texture `uri`s. Embedded and `data:` images are allowed.
      - Textures over 4096² each, or 2 × 4096² in total, read from the image headers before decoding.
      - A non-object JSON chunk.
      - Non-finite vertices or UVs.
    - The total face count after decimation is a hard cap. Each part keeps min(its faces, 4) and the rest is shared by size. "Too many parts" is raised only when those floors alone exceed the budget.
    - Points and `st` are written with `%.7g`. Vertex normals are area-weighted in numpy, because trimesh's own normals need scipy and otherwise take a slow fallback.
  - Measured (M-series Mac, Python 3.12):
    - Without decimation, 327,680 faces gives an 18.7 MB USDZ in 424 s (per-element formatting). Unusable.
    - Decimated to 40k: 2.17 MB in 6.6 s.
    - Decimation plus array-level formatting plus numpy normals: 327,680 faces (7.2 MB GLB, 2048² texture) gives a 2.67 MB USDZ in 0.5 s. It passes `usdchecker --arkit` and loads textured in RealityKit.
  - Rejected: `usd-core` (201 MB unzipped, against Vercel's 250 MB function limit).
  - Rejected: an iOS GLTF package (new SPM dependency through xcodegen, unclear RealityKit support).
  - New dependencies: numpy (16.5 MB wheel), trimesh, fast_simplification (1.7 MB wheel).
  - **Vercel duration:** the repo has no `vercel.json` and no `maxDuration`, so the plan's default limit applies. The poll that finishes a job downloads up to 40 MB from fal's CDN and then converts it (about 0.5 s measured), so it needs roughly 10–30 s on a slow link. Set `maxDuration` to at least 60 for `main.py` before relying on it.
- App flow, from the "Add to room" placement's panel, with "Make it 3D (beta)":
  1. Poll the job.
  2. Download the model and store it as `Objects/<id>/model.usdz`.
  3. Create a `ScannedObject` with `boundingBox` = product dimensions.
  4. Point the placement at it. The existing scanned-object path renders it.
  5. Keep the box if any step fails.
- SAM 3D output scale is not metric. Always fit the mesh bounds to `dimensions_cm`, or to the catalog size if the product has no dimensions.

### 7. Demo safety

- Bundle one recorded `/vibe/shop` result (products + images) for the demo prompt. The app uses it when the backend or the agents are unreachable.
- Pre-generate the SAM 3D model for one demo product.
- Update `docs/DEMO.md` beat 2:30: type a prompt with a budget → agents stream in products → "Add to room" → the item appears in the Designer.

## Non-goals

- No purchasing, cart, login, or saved payment details. Agents only read public product pages.
- No Facebook Marketplace, through any path.
- No currency other than USD; no shipping or tax estimates.

## Checks

- `backend/test_main.py`:
  - analyze with text only, image only, both, and neither (400).
  - Shop start/poll with a mocked Browser Use transport (running → done, one failed run).
  - The Facebook URL filter.
  - `MOCK=1` works with no keys.
- `backend/test_budget.py`: picks within budget, prefers covering more items, ignores unpriced items, and handles a budget too small for anything.
- App UI test against `MOCK=1`: prompt → streamed products → "Add to room" → a placement exists with `product` set.
- No API key in the iOS target or in git.
