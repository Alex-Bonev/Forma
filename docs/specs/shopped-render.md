# Spec: Shopped products stay themselves in "Make it real"

Status: **draft**. Owner: C (David). Branch `c/shopped-render`, on top of `c/vibe-room-integration`.

## Problem

Plan (Vibe) → place (Add to room) → Make it real loses the product. A shopped product reaches `/render` only as:
- a generic catalog stand-in (Kenney model) in the snapshot, painted the same blue as every placement in the
  structure map;
- its listing title in the layout text ("UBesGoo Modern Arm Chair… (armchair)").

The image model never sees the product, so it renders a generic armchair. The faithful rules make this worse:
they tell it to make each stand-in "a real piece of that type" and to take looks from the scan photos, which
can't show a piece the user hasn't bought yet.

## Goal

In a plain Make it real, each shopped product looks like its product photo: shape, color, material. It keeps the
stand-in's footprint, height, position and facing. Rooms without shopped products render exactly as before.

## Design

The product photo goes to `/render` as one more reference image, and it is tied to its stand-in two ways:
- **Structure map:** each shopped product (up to 3) gets its own flat color instead of the shared placement blue.
  The legend names it: "product 1 pink".
- **Layout text:** the product's entry says "product 1" and that it must match its product photo.

The backend owns image numbering (it already does for structure, style ref and scan photos). The app sends the
photos in product order, and the backend writes "Image K is the product photo for product N (<title>)".

### 1. Product photos on the device (`Core/ProductPhotos.swift`)

- Stored per placement: `Projects/<projectID>/products/<placementID>.jpg`, JPEG ≤ 768 px.
  - Why store it: the listing image can disappear, and the demo's `bundle:` images are stored in the placement
    as an absolute `file://` path into the app bundle, which changes on every reinstall or update.
  - Not for offline renders: `/render` always needs the network. The render cache is only a stale fallback.
- `cache(_ product:, placement:, project:) async`: downloads `imageURL` with a 10 s timeout, then downscales and
  writes the file. It skips if the file exists. Failure is silent: the product then renders as a named stand-in,
  like today.
  - Accepted URLs: https, or a file URL inside `Bundle.main` (the demo). No other file URLs: the URL comes from
    the server, and the file is uploaded.
  - A stale demo file URL (old bundle path): retry `Bundle.main.url(forResource:withExtension:)` with its last
    path component. Without this, the lazy cache below fails after a reinstall.
  - Empty or missing `imageURL`: no photo.
- Called right after "Add to room" / "Add all" (VibeView), and again lazily before a render for any missing file.
  Downloads run in parallel, so a render waits at most about 10 s.
- `load(placement:, project:) -> UIImage?`.
- Placement removal leaves the file. The project folder holds it, so deleting the project removes it.
  Accepted: a few orphaned files of about 100 KB each.

### 2. Structure map (`Features/Render/StructureMap.swift`)

- `render(…, products: [UUID])`: placement ids in product order (1…3).
- New kinds `product1`…`product3`: pink `[1, 0.55, 0.75]`, lime `[0.6, 1, 0.2]`, mint `[0, 1, 0.5]`.
  - Depth shading scales all three channels by 0.45–1, so it changes brightness, not hue. Colors must differ in
    hue from every existing kind, not only in brightness.
  - Hues: pink 333°, lime 90°, mint 150°. Nearest existing: red 0°, magenta 300°, yellow 60°, green 120°, cyan
    186°. Each is at least 27° away.
  - Rejected: teal `[0, 0.65, 0.6]` (175°, a far window's cyan darkens to about the same color) and peach
    `[1, 0.8, 0.55]` (33°, the same hue as chair orange; a far peach is close to door brown).
  - No 4th free hue: the gaps left are near blue, navy and purple. Hence 3 products.
- Legend: "product 1 pink", and so on, only for the ones visible.
- Every other placement stays `placedObject` blue.

### 3. Layout text (`Features/Render/RenderInputs.swift`, `LayoutDescription.swift`)

- `RenderInputs.scene` also returns `shopped: [(id: UUID, product: ShopProduct)]`, every shopped placement in
  placement order. `run()` numbers the first 3 whose photo loads (section 5).
- `LayoutDescription.text` takes those numbered ids, so `run()` rebuilds the layout once the list is fixed.
- Their layout entry reads: `<title> (product N: a new piece the user is buying; make it look exactly like its
  product photo, <w> m wide, …, <spot>)`. Other placements keep today's wording.
- Cap each listing title at 60 characters in the layout. The backend cuts the layout at `MAX_LAYOUT` (2000), and
  the app appends the structure-map legend last, so long titles would cut the product colors off first.

### 4. Backend (`/render`)

- New optional repeatable multipart fields: `products` (images, ≤ `MAX_PRODUCTS` = 3, inside the existing
  combined `MAX_UPLOAD` cap) and `product_names` (text, same order; missing or extra names are tolerated).
  Images come after the scan photos.
  - At most 9 images per request: snapshot, structure map, style ref, 3 scan photos, 3 products.
  - Size: 3 × 768 px JPEGs add about 0.3 MB, well inside `MAX_UPLOAD` (10 MB default).
- Prompt, when products are present, for both the faithful rules and the restyle rules: "Images K to K+n-1 are
  product photos of new pieces the user is adding, which are not in the scan photos. Image K is product 1
  (<name>): …. Render each numbered product exactly like its photo (shape, color, material, details) at the
  size, position and facing of its stand-in in image 1 (its color in the structure map). Use only the product
  itself: ignore the photo's background, props and other items."
- The faithful rules' "make it look like a real piece of that type" and the photo rule's "give each stand-in the
  look of the matching real piece in the photos" gain "unless it is a numbered product".
- `MOCK=1`: unchanged (echoes the snapshot).

### 5. App wiring (`RenderView.swift` `RenderModel`, `APIClient.render`)

- `APIClient.render(…, products: [(name: String, image: UIImage)])`: adds the `products` and `product_names`
  fields.
- `RenderModel.setRoom` keeps the shopped placements. The first `run()` caches any missing photos, then fixes the
  numbered list from the photos that loaded. The layout text, the structure map and the upload all use that one
  list, so product N means the same piece in all three.
- The list is fixed once, like the structure map (`structure == nil`). A view switch or retry reuses it, even if a
  photo arrives later: renumbering would not match the cached map.
- Cache key: unchanged (prompt and style ref). It already ignores room edits; the cache is the network-failure
  fallback, shown with its own "before" snapshot. Adding product ids would only hide the fallback after an add.

## Out of scope

- The Vibe screen's own restyle render: products aren't picked yet when it runs.
- More than 3 products: the rest render as named stand-ins.
- Making the snapshot itself show the product (that's "Make it 3D", already built).

## Checks

- `backend/test_main.py`: product images are numbered after the scan photos, capped at 3, names attached,
  prompt text present only with products, and the combined upload cap still applies.
- App build. The `VibeShoppingTests` UI tests still pass against `MOCK=1`.
- A new UI test: add a shopped product, then Make it real against the mock, which renders without an error.
- One real render (Gemini, paid) on the demo room with a shopped armchair: the armchair matches its photo.
  Run only with the owner's OK.
