# UI wiring report for David (Owner C)

From Michelle (B), branch `b/forma-ui`. The Paper "forma" design is now in the app. Your Render and Vibe screens are merged (PR #4). The new UI now opens `RenderView` from a "Make it real" button; nothing opens `VibeView`. Alex's draft PR #6 (`a/make-it-real`) adds a "Make it real" button to the old Designer chrome, so it overlaps this branch's `DesignerView`. This lists what is still open on your side.

## Decision from Michelle

"Make it real" is in the app. It turns the 3D render of the furnished room into a hyperrealistic render of that room, using your `/render` backend and `RenderView`.

- **Where the button is.** On Room detail it sits left of the fullscreen button on the room card. In fullscreen it sits under the back (exit) button. While the Objects panel is open it shrinks to an icon-only circle.
- **What it does.** `DesignerView.makeItReal()` calls `captureDesignerSnapshot()`, builds a `RenderCamera` from the Designer camera, and presents `RenderView(snapshot:projectID:camera:)` as a sheet.
- **Look.** Sand fill (`Theme.sand`), sage outline, `Theme.ink` text, sage-deep sparkle. See `MakeItRealButton` in `Features/Home/FormaParts.swift`.
- **PR #6.** It targets the old Designer chrome and conflicts with this branch. Rebase it onto the Paper top bar or close it; the button itself is already here. That is Alex's and your call.
- **Not decided here:** whether to delete the parked Vibe code (`VibeView`). I left it alone.

## Still open on your side

1. **Loading screen is reusable.** `LoadingView(status: String?)` in `Features/Home/StartView.swift` is the Paper Loading screen. It is the app splash. Use it for any long network wait.
2. **"No connection · retrying" is cosmetic.** The splash shows it when the device has no network (`Connectivity`, an `NWPathMonitor` wrapper). Nothing retries. If you keep any API call, tell me the state to show.
3. **Style.** If any of your screens stay in the app, use `Theme`, `.font(.forma(...))` and `PillButtonStyle` from `Core/Theme.swift`. Sage fills use `Theme.onSage` (`#FBF8F3`) for text and icons.

## Reply from David (C), branch `c/make-it-real`

1. **Loading screen:** done. `RenderView` shows `LoadingView(status: "Making it real · about 30 s")` while `/render` runs.
2. **"No connection · retrying":** now true for Make it real. `Connectivity` is in the environment (`RoomVibeApp`).
   While the sheet is open, `RenderView` re-runs a failed or offline (cached) render when the device comes back
   online. The splash line is still cosmetic: the `/health` ping at launch (to wake the backend) runs once, no retry.
3. **Style:** the Make it real sheet uses `Theme`, Space Mono, `PillButtonStyle` and a sage Dollhouse / Photo switch.
   It is light-only now. The nav bar title stays "Make it real" (Alex's UI test in PR #9 looks it up).
4. **Selection markers in the snapshot:** Alex's PR #9 (`a/render-clean`) clears them before capture. I left
   `DesignerView` alone so the two branches do not conflict.

## Not touched

I did not edit `backend/`, `Core/Networking/`, `Features/Render/` or `Features/Vibe/`, except one expression in `Features/Render/StructureMap.swift` that does not compile with Xcode 26.2 here (see PR #7).
