# UI wiring report for Alex (Owner A)

From Michelle (B), branch `b/forma-ui`. The Paper "forma" design is now in the app (Start, Loading, Home, Room detail, Object detail, fullscreen 3D with the Objects panel). This lists what is wired and what still needs your side.

## What I wired to your code (please check these)

- **Rescan room** (Room detail > Rescan > confirm sheet > "Start rescan") presents your `RoomScanView`. Its `onSaved` returns a *new* `Project`. I copy the old project's name, placements, `wallFinish` and `floorFinish` onto the new one, delete the old project, and swap the navigation route. See `RoomDetailView.replace(_:with:)`.
  - Open: `hiddenRoomObjects` is not carried over, because the indices belong to the old scan.
  - Open: if you would rather rescan in place (same project id, new `room.json`), add that to `ProjectStore` and I will call it.
- **Rescan object** (Object detail > Rescan) presents your `ObjectScanView { fresh in ... }`. I rename the new object to the old name, point every placement that used the old object at the new one, then delete the old object. See `ObjectDetailView.replace(_:with:)`.
- **Scan Room / Scan Object** on Home still present your views unchanged. Both Rescan buttons and both Scan buttons are disabled when `Capabilities` says no LiDAR.

## Still needs you

1. **Real room thumbnails.** Home and the add-to-room sheet draw a fixed stylised glyph (`RoomGlyph`). Paper shows a drawing too, but a real thumbnail is better. Suggestion: save `Projects/<id>/thumb.png` at the end of a room scan (top-down or 3/4 render), and I will load it when it exists.
2. **Real object thumbnails.** The Object library grid shows an SF Symbol for every object. If `ObjectScanView` makes a thumbnail, save it to `Objects/<id>/thumb.png`, or add an optional `thumbnail: String?` to `ScannedObject` (I own `Models.swift`; tell me the name and I will add it). I will show it on Home and in the object detail.
3. **Bundled demo chair colour.** The demo chair renders orange in the object preview. Paper shows a dark wood chair. This is a material colour in the demo asset.
4. **Your scan screens are not restyled.** `RoomScanView`, `ObjectScanView` and `RoomPhotosView` still use system styling. Use `Theme` (colors), `.font(.forma(...))` (Space Mono) and `PillButtonStyle` from `Core/Theme.swift` if you want them to match. Sage buttons must use `Theme.onSage` text (`#FBF8F3`). I removed the app-wide `.tint(Theme.sage)` I added earlier so your `.borderedProminent` buttons are not white-on-sage.
5. **UI test `testRenameObject` was already failing** on `main` before my changes, and fails earlier now: the system navigation bar is hidden on Home and Room detail, so `app.navigationBars.buttons.firstMatch` finds nothing, and object tiles are now navigation buttons (open Object detail; rename is still on long press). The Back buttons are labelled "Back to Rooms" and "Back to Library". Please update that test; the other four pass.
6. **`-demo` launch** still opens the Designer directly (`Route.designer`), skipping Start and the loading splash, so the UI tests keep working.

## Files I changed that you own or share

- `Core/Models.swift`: not changed in this branch.
- `Features/Designer/RoomBuilder.swift`: added `RoomBuilder.bounds(_:)` (extracted from `build`, behaviour unchanged).
- New files: `Core/Theme.swift`, `Resources/Fonts/SpaceMono-*.ttf` (OFL), `Features/Home/{StartView,FormaParts,RoomDetailView,ObjectDetailView,Router}.swift`.
