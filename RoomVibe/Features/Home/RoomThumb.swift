import SwiftUI

/// Room thumbnail: the Designer's default view saved as `Projects/<id>/thumb.jpg` (DesignerView.saveThumbnail).
/// Falls back to the glyph until the room has been opened once.
struct RoomThumb: View {
    let projectID: UUID
    @State private var image: UIImage?

    static func url(_ id: UUID) -> URL { ProjectStore.projectDir(id).appending(path: "thumb.jpg") }

    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFill() } else { RoomGlyph() }
        }
        .onAppear { image = UIImage(contentsOfFile: Self.url(projectID).path(percentEncoded: false)) }   // reload after edits
        .accessibilityHidden(true)
    }
}
