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
  - Placed at the floor spot nearest the room center that does not overlap existing boxes, or the room center if none is free.
  - `scale` set so the model matches `dimensions_cm` when present; otherwise the catalog size.
- New optional field `Placement.product: ShopProduct?` (title, price, product_url, image_url). Old projects decode unchanged.
  - **Models.swift is B's file.** Agree on the field name with B before editing.
- In the Designer's selected-object panel, a placement with `product` shows its title, price and an "Open product" link.
  - **DesignerView.swift is B's file.** B adds this, or approves the diff.

### 6. Real 3D model with SAM 3D (reach)

- `POST /vibe/model3d` with JSON `{image_url, category}`:
  - Submits to the fal queue with `prompt = category` and `export_textured_glb = true`.
  - Returns `{request_id}`.
- `GET /vibe/model3d/{request_id}` returns `{status, model_url?}`.
- `MOCK=1` returns a bundled sample model URL.
- **GLB → USDZ.** RealityKit loads USDZ, not GLB. Spike both options and pick one:
  - **(a) Backend:** convert with `usd-core` + `trimesh` (textured mesh → UsdPreviewSurface). Risk: wheel size against Vercel's function size limit.
  - **(b) App:** load GLB with a GLTF Swift package. Risk: new dependency, and RealityKit support.
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
