# UI wiring report for David (Owner C)

From Michelle (B), branch `b/forma-ui`. The Paper "forma" design is now in the app. Your Render and Vibe screens are merged (PR #4), but nothing in the new UI opens them yet. Alex's draft PR #6 (`a/make-it-real`) adds a "Make it real" button to the old Designer chrome, so it will conflict with this branch's `DesignerView` and needs rebasing onto the Paper top bar. This lists what is still open on your side.

## Decision from Michelle

"Make it real" is not needed in the app, so the Paper UI has no button for it and I did not add one. Nothing opens `RenderView` or `VibeView`. Alex's draft PR #6 (`a/make-it-real`, adds the button) should not be merged. Whether to delete the merged Render and Vibe code (PR #4) is your and Michelle's call; I left it alone.

## Still open on your side

1. **Loading screen is reusable.** `LoadingView(status: String?)` in `Features/Home/StartView.swift` is the Paper Loading screen. It is the app splash. Use it for any long network wait.
2. **"No connection · retrying" is cosmetic.** The splash shows it when the device has no network (`Connectivity`, an `NWPathMonitor` wrapper). Nothing retries. If you keep any API call, tell me the state to show.
3. **Style.** If any of your screens stay in the app, use `Theme`, `.font(.forma(...))` and `PillButtonStyle` from `Core/Theme.swift`. Sage fills use `Theme.onSage` (`#FBF8F3`) for text and icons.

## Not touched

I did not edit `backend/`, `Core/Networking/`, `Features/Render/` or `Features/Vibe/`, except one expression in `Features/Render/StructureMap.swift` that does not compile with Xcode 26.2 here (see PR #7).
