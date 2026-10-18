# UI wiring report for David (Owner C)

From Michelle (B), branch `b/forma-ui`. The Paper "forma" design is now in the app. Your Render and Vibe screens are merged (PR #4), but nothing in the new UI opens them yet. Alex's draft PR #6 (`a/make-it-real`) adds a "Make it real" button to the old Designer chrome, so it will conflict with this branch's `DesignerView` and needs rebasing onto the Paper top bar. This lists what is still open on your side.

## Still needs you

1. **No entry point for "Make it real" or Vibe in the Paper design.** Paper has no button for either, so I did not add one. PR #6 has the Make it real button; decide with Michelle where it goes in the Paper top bar. Vibe has no entry point at all. The least invasive options are a "Make it real" pill in the fullscreen Designer's top chrome (next to Objects), or a button on Room detail under the 3D card. Once you merge, tell me the names and I will add the button.
2. **Contract for the button:** it will call your `captureDesignerSnapshot() -> UIImage?` (from `Features/Render/Snapshot.swift`) and present `RenderView(snapshot:projectID:)`. Notes:
   - The snapshot finds the largest Metal view on screen. In the fullscreen Designer this is the room. On Room detail it is the small card, which is low resolution. Capture from the fullscreen Designer only, or take the larger frame.
   - The fullscreen Designer now has top chrome, the Objects panel and controls drawn over the 3D view. Your snapshot only draws the Metal view, so those do not appear in the image. Please confirm on device.
3. **Loading screen is reusable.** `LoadingView(status: String?)` in `Features/Home/StartView.swift` is the Paper "Loading" screen (sage square circling the ring, 1.2 s loop, honours Reduce Motion). It is wired as the app splash. It is not used for render or vibe waits yet. To use it, show it in a full-screen cover with a status line such as "Rendering your room". `RenderView` currently shows a white `ProgressView`.
4. **"No connection · retrying" is only cosmetic right now.** The splash shows it when the device has no network (`Connectivity`, an `NWPathMonitor` wrapper in `StartView.swift`). Nothing retries. `APIClient` has no retry or offline state. If you add one (for example `APIClient.isRetrying`), I can drive the status line from it, and `RenderView` can show the same line.
5. **Style.** `RenderView` and `VibeView` use system styling. To match the app, use `Theme` (colors), `.font(.forma(...))` (Space Mono) and `PillButtonStyle` from `Core/Theme.swift`. Sage buttons and fills must use `Theme.onSage` (`#FBF8F3`) for text and icons, never dark text.
6. **Offline fallback.** `docs/DEMO.md` expects cached render results when Wi-Fi fails. Nothing in the UI shows a cached result yet.

## Not touched

I did not edit anything in `backend/`, `Core/Networking/`, `Features/Render/` or `Features/Vibe/`.
