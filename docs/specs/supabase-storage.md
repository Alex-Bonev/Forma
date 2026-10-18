# Spec: Supabase as the app's data storage

Status: **in progress**. Owner: C (David). Branch `c/supabase`, off `main` at PR #21, then `main` at PR #23 (My Vibes) merged in.

## Goal

Every piece of data the app keeps today is mirrored to one Supabase project, so a library survives a lost or wiped
phone and the backend can trust who is calling it. The app stays local-first: Application Support remains the working
copy that RealityKit loads from, and the app keeps working offline and without a cloud config.

Out of scope: sharing a library between two devices or people (needs real accounts), realtime updates, server-side
AI job state (providers hold it; the backend stays stateless).

## Data inventory (main @ PR #23)

| Data | Written by | Local | Supabase |
| --- | --- | --- | --- |
| Room entry: name, placements (incl. shopped `ShopProduct`), finishes, hidden/removed items | `ProjectStore` | `library.json` | `projects.doc` jsonb |
| Room geometry `RoomModel` | `ProjectStore.addRoom` | `Projects/<id>/room.json` | `projects.room` jsonb |
| RoomPlan capture, room export | `RoomScanView` (in `addRoom`) | `captured.json`, `room.usdz` | bucket `library` |
| Scan photos + index | `RoomPhotos.write`, `addBundledDorm` | `photos/*.jpg`, `photos/photos.json` | bucket |
| Room thumbnail | `DesignerView.saveThumbnail`, demo seeding | `preview.jpg` (legacy `thumb.jpg`) | bucket |
| Latest render + its "before" | `RenderView` (one per room, older `render-*` deleted) | `render-latest.jpg`, `render-latest.before.jpg` | bucket |
| Object entry: name, model file, bounding box | `ProjectStore` | `library.json` | `scanned_objects.doc` jsonb |
| Object model + thumbnail (Object Capture, or SAM 3D) | `ObjectScanView`, `saveModel` | `Objects/<id>/model.usdz`, `thumb.jpg` | bucket |
| Saved vibe: name, styles, mood, colors, materials, description, custom instructions | `VibeLibrary` | `Vibes/vibes.json` | `saved_vibes.doc` jsonb (task 6) |
| Vibe inspiration photos (1–15) | `VibeLibrary.add` | `Vibes/<id>/<n>.jpg` | bucket, `<user>/vibes/<id>/` (task 6) |
| Room's applied vibe `Project.vibeID` | `RoomVibePicker`, `CreateVibeView`, `VibeDetailView` (via `store.update`) | `library.json` | inside `projects.doc` |
| Object Capture inputs | `ObjectScanView` | `Images/`, `Checkpoint/` (deleted after build) | not synced |
| Per-device settings: intro seen, dorm seeded, realistic furniture, use photos in renders | `@AppStorage` | UserDefaults | not synced |
| Auth session (refresh token) | `CloudClient` | Keychain | Supabase Auth |
| Backend | — | stateless | verifies the Supabase user (task 5) |

## Already built (ported from `c/supabase-storage`)

- Schema `supabase/migrations/20261018062400_library.sql`, applied to project `hoihybbcwljxkambccqd`:
  owner-scoped RLS, tombstones (no DELETE grant), a last-writer-wins trigger, private `library` bucket.
- `Core/Cloud/CloudClient.swift`: REST client for Auth (anonymous), PostgREST and Storage.
- `ProjectStore` hooks: `updatedAt`, pending deletes, `applyRemote`, `onChange`, `filesChanged`.
- `Core/Cloud/CloudSync.swift`: a pass on launch, foreground and 2 s after a change.

## Gaps this spec closes

1. **File deletes never sync.** The per-file merge sees "only in the cloud" as "new there" and downloads it again.
   RenderView's cleanup of old `render-*` files, and any future file delete, comes back on the next pass.
2. **Files written outside the store don't trigger a pass.** `RenderView` writes the render cache without telling sync.
3. **UI tests would wipe the cloud library.** `-fresh` deletes every room; with sync on, that sends tombstones.
4. **Duplicate demo rooms.** A reinstall keeps the cloud user (Keychain), seeds the UCLA dorm, then pulls the
   cloud's copy of it: two dorms.
5. **The backend trusts a shared secret bundled in the app.** It should accept the Supabase user's token.
6. **Saved vibes (PR #23) are device-only.** `VibeLibrary` has no sync hooks, and `-seedVibe` (UI tests) deletes
   every vibe.

## Tasks

Each task: an agent implements it, a second agent reviews the diff, findings are fixed, then one commit on `c/supabase`.

1. **Three-way file merge.** Keep the last synced manifest per item (`Application Support/sync-state.json`, written
   only by CloudSync). Per file, with base B, local L and remote R:
   - L and R agree: nothing.
   - In B, missing in L, R unchanged from B: deleted here, so remove it from storage.
   - In B, missing in R, L unchanged from B: deleted elsewhere, so delete the local file.
   - Otherwise: the newer copy wins, as today.
   No base (first sync of an item, or an old install) keeps today's behaviour. The base updates after each successful
   item sync and is dropped when the item is deleted.
2. **Notify sync of every out-of-store file write.** `RenderView` calls `store.filesChanged()` after writing or
   pruning the cache. Audit every other writer in the inventory above; writers inside `addRoom`/`addObject` need nothing.
3. **Safe launch order.**
   - No CloudSync, and no pending deletes, when the app runs with `-demo` or `-fresh` (UI tests).
   - The first-launch dorm seeding in `HomeView` waits for the first sync pass, then seeds only if no room with that
     name exists (from the cloud or local).
4. **Backend accepts the Supabase user.** With `SUPABASE_URL` set on the backend, a request passes with
   `Authorization: Bearer <access token>` verified against the project's JWKS
   (`/auth/v1/.well-known/jwks.json`, cached) or with the existing `X-App-Secret`. The app sends its access token
   when it has a cloud session. MOCK=1 stays open, as today. Tests cover valid, expired, wrong-audience and
   wrong-issuer tokens.
6. **Sync saved vibes.** Migration `saved_vibes` (same shape, RLS, tombstones and trigger as `scanned_objects`);
   `VibeLibrary` gets ms-rounded stamps, pending deletes, `applyRemote` / `removeRemote` and `onChange`, like
   `ProjectStore`; CloudSync syncs vibes before rooms (a pulled room's `vibeID` then resolves). `-seedVibe` joins the
   task 3 guard. A vibe deleted elsewhere leaves `vibeID` on rooms here; lookups already treat it as no vibe.
5. **Docs and end-to-end check.** README storage map (this inventory), STATUS entry, and a Simulator run against the
   real project: a room and an object reach the tables and the bucket, an edit and a delete round-trip.

## Manual steps (not doable by an agent)

1. Supabase dashboard > Authentication > Sign In / Providers: turn on **Allow anonymous sign-ins**. Until then
   nothing can sign in and task 5's end-to-end check is blocked.
2. Recommended with anonymous sign-ins on: Authentication > Attack Protection, turn on CAPTCHA or keep the
   sign-up rate limit low, since anyone with the app can create users.
3. `backend/.env`: `SUPABASE_URL=https://hoihybbcwljxkambccqd.supabase.co` and `SUPABASE_PUBLISHABLE_KEY`
   (Project Settings > API Keys, the `sb_publishable_` one). Then `scripts/run_local.sh` and rebuild the app.
4. On the demo phone: scan a room and an object, then reinstall the app and check the library comes back.
5. Review and merge the PR for `c/supabase`. `c/shopped-render` is still unmerged and touches `ProjectStore.swift`
   and `DesignerView.swift`: merge it first, or expect conflicts.

## Known limits (accepted)

- One anonymous user per install; a second device is a separate library.
- A device clock more than 5 minutes fast keeps re-sending its items.
- A file whose upload landed but whose row write failed stays in storage after a delete.
- Each pass reads every row; fine for a demo-sized library.
- A delete on another install wins over file-only changes here (a newer thumbnail or render): file writes do not
  stamp the item, so they never beat real edits elsewhere.
