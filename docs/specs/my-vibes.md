# Spec: My Vibes (inspiration photos → saved aesthetic profile → room)

Status: **implemented**. Matches `backend/main.py` (`/vibe/profile`), `RoomVibe/Core/SavedVibe.swift` and `RoomVibe/Features/Vibe/`. UI source of truth: Paper file "Youthful feather", page "forma — v2", frames "v2 · A3", "E4", "E5", "M" to "R".

## Scope

A user adds 1 to 15 inspiration photos. One vision-model call turns them into a reusable profile (a "vibe"). The user edits and saves it, and can apply it to a room. Furniture search and Browserbase are **not** part of this feature; the saved profile and `getVibeAgentPrompt` only prepare their input.

## Profile (`POST /vibe/profile`)

- Input: multipart `images`, 1 to 15 files, each JPEG/PNG/WebP/GIF (sniffed, not trusted from the extension). The app resizes to a 1024 px long edge, JPEG 0.7, before sending.
- One `messages.parse` call to Claude carries every image plus the prompt. The model reads the images as taste, not as a list of objects.
- Output (validated against the `VibeProfile` model, then cleaned by `clean_profile`): `name`, `styles`, `mood`, `colors[{name, hex}]`, `materials`, `textures`, `motifs`, `lighting`, `furniture_characteristics`, `avoid`, `description`.
  - Cleaning: trimmed and de-duplicated tags, at most 8 per list; colors kept only if `#RRGGBB`, at most 8, hex upper-cased; name at most 60 characters, falls back to "My Vibe".
  - **`description` is a design brief of about 80 to 120 words. The backend accepts 70 to 130 words (`DESC_WORDS`); outside that it returns 502 and the user can try again.**
- Errors: 400 wrong image count, 413 over `MAX_UPLOAD_MB` in total, 415 unsupported image, 501 `LLM_API_KEY` missing, 502 model failure or bad profile, 504 timeout.
- `MOCK=1` (default) returns a canned "Enchanted Cottage" profile. Real analysis needs `LLM_API_KEY` and `MOCK=0`.
- Keys stay on the backend. The result is stored, so viewing or editing a saved vibe never calls the model.

## Storage (device only)

No auth or cloud storage exists, so vibes belong to the app install.

- `Application Support/Vibes/vibes.json` is the index (`SavedVibe`: profile fields, `imageFiles`, `customInstructions`, `createdAt`, `updatedAt`). Images are JPEG files in `Vibes/<id>/`, never inside the index.
- `VibeLibrary`: `add`, `update` (bumps `updatedAt`), `delete`. A failed save leaves no files behind. An unreadable index is moved to `vibes.json.bad`.
- Room link: `Project.vibeID` (optional). Deleting a vibe clears it on every room that used it.

## Agent brief

- `getVibeAgentPrompt(_ vibe: SavedVibe) -> String`: description, styles, mood, colors, materials, textures, motifs, lighting, furniture, avoid, and the user's custom instructions (which win).
- `getRoomVibeBrief(room:library:)`: room name and vibe name plus the above, built fresh each time; nil when the room has no vibe.
- Nothing calls Browserbase yet.

## UI

All vibe screens use the app's Space Mono type (no system serif). Keep labels single: a title never repeats in a caption or button.

- **Home > Vibes:**
  - A dashed "New vibe" card comes first.
  - Then one card per vibe: a 2×2 photo tile, name, styles and color dots.
  - Room chips show only when the vibe is used in a room.
- **Create:**
  - "Photos you love" (n of 15, remove with x, dashed + tile), then "Find my vibe".
  - One call, with Cancel.
  - Review in `VibeFields`, then "Save vibe".
  - Notices (skipped files, failed with Retry, save failed) are one-line cards with a dismiss x.
- **`VibeFields`** (shared by review and details):
  - Shown first: name (`NameField`), colors, Styles, Mood, Materials, Avoid and Instructions.
  - "More details" reveals Textures, Motifs, Lighting, Furniture and Description.
- **Details:**
  - The same `DetailBar` as rooms ("‹ Vibes", Delete), then the collage and `VibeFields`.
  - Edits autosave after 0.6 s and on leaving. There is no Save button.
  - Delete asks once ("Delete this vibe?").
- **Room detail row and Designer pill** (the pill sits at the bottom left, on one row with Feng-shui-ify on the right, just above Make it real; its menu opens upward):
  - With no saved vibes, they open New vibe directly.
  - Otherwise a list of vibes, "New vibe", and "Remove" (only when one is applied).
  - The Paper E4 sheet was removed.
- **Shop a vibe:**
  - When the room has a vibe, that vibe is the input: its first photo is the style reference, and `getRoomVibeBrief` is the prompt. What the user types goes first so a budget survives the 1000-character cap.
  - The x sets the vibe aside to use a one-off photo or words instead.
  - Way in: the Make it real sheet has an outlined "Shop <vibe name>" (or "Shop a vibe") pill above Compare/Image. It also shows after a failed render.
  - Make it real stays faithful and ignores the vibe.
- **Saved run:** each room has one run (`VibeModel.forRoom`), and it outlives the screen.
  - Leaving Shop a vibe doesn't stop the restyle or the agents.
  - The run is saved to `Projects/<id>/vibe-latest.json`, plus `vibe-latest.jpg` (the restyle) and `.before.jpg`. It holds the style, rows, picks, budget and the agents' job token.
  - Reopening shows the run at once ("Last run · 5 min ago").
  - After a relaunch, polling resumes from the job token (it is stateless on the backend). A missing restyle is redone.
  - "Try again" replaces the run. Retry after a failed poll resumes the same job instead of paying for new agents.
- **Grounded restyle:**
  - The restyle sends the same inputs as Make it real (`RenderModel.grounding`): the layout text, the structure map from the Designer camera, the view mode (cutaway or interior, from the camera angle) and product photos.
  - Backend `RESTYLE_RULES` fixes the geometry: same camera, size and walls; no new walls, floors or rooms; the area outside the walls stays background; no added furniture.
  - The style reference may be used only for looks, never for its room.

## Known gaps

- The skipped-files notice gives a count, not file names.
- The offline pill is not built on these screens.
- No Swift unit-test target exists; backend tests cover the profile endpoint.
