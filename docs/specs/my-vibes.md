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

- Home: sticky Rooms / Objects / Vibes tabs. The Vibes tab shows a dashed "+ Vibe" card, then cards with a 2×2 photo tile, name, styles, color dots and the rooms using it ("Not in a room yet" otherwise).
- Create: pick photos (remove with x, dashed Add tile, "n / 15") → "Find My Vibe" → one call with Cancel → review (editable name with "suggested by AI", colors, tag groups, description, custom instructions) → "Save Vibe". Inline notices: skipped files, request failed (Retry, Back to photos), empty name, save failed.
- Details: editable name, "Used in …", collage, colors, tag groups, description, custom instructions, dates, "Save Changes" (disabled until edited), "Delete" with the confirm card ("Delete this vibe?").
- Room fullscreen: a Vibe pill next to "Make it real". No vibe opens the "Add a vibe" sheet; with a vibe the pill opens a dropdown (switch, "New vibe from photos", "Remove vibe from room"). Apply and Remove only write `Project.vibeID`; the Make it real render is not changed.
- Green buttons and fills use `#FBF8F3` for text and icons.

## Known gaps

- Fraunces is not bundled; serif headings use the system serif.
- The skipped-files notice gives a count, not file names.
- The offline pill is not built on these screens.
- No Swift unit-test target exists; backend tests cover the profile endpoint.
