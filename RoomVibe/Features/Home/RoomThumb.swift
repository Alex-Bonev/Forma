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

/// Library tile image: the scan's `Objects/<id>/thumb.jpg` (ObjectScanView), else the chair symbol.
/// QuickLook thumbnails are white with a 3D badge top-right: the edges are cropped off and the white is
/// multiplied into the tile color.
struct ObjectThumb: View {
    let object: ScannedObject
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFit().blendMode(.multiply).padding(6)
            } else {
                Image(systemName: "chair.lounge.fill").font(.system(size: 30)).foregroundStyle(Theme.wood)
            }
        }
        .task(id: object.id) {
            let url = ProjectStore.objectDir(object.id).appending(path: ObjectScanModel.thumbnailName)
            guard let cg = UIImage(contentsOfFile: url.path(percentEncoded: false))?.cgImage else { return }
            let inset = CGFloat(cg.width) * 0.16   // badge sits in the top-right 15%
            image = cg.cropping(to: CGRect(x: 0, y: 0, width: cg.width, height: cg.height).insetBy(dx: inset, dy: inset))
                .map { UIImage(cgImage: $0) }
        }
        .accessibilityHidden(true)
    }
}
