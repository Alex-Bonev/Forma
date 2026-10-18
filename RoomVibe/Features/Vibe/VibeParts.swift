import ImageIO
import SwiftUI

/// Shared building blocks for the My Vibes screens (Paper frames "v2 · A3", "M" to "R", "E4", "E5").

/// Up to four stored inspiration images as a 2x2 tile. Falls back to the palette's colors where an image is missing.
struct VibeTile: View {
    @Environment(VibeLibrary.self) private var library
    let vibe: SavedVibe
    var corner: CGFloat = 20
    /// false: fill whatever frame the caller gives (Home cards are wider than tall).
    var square = true

    var body: some View {
        let urls = vibe.imageFiles.prefix(4).map { library.imageURL(vibe, $0) }
        VStack(spacing: 2) {
            HStack(spacing: 2) { cell(urls, 0); cell(urls, 1) }
            HStack(spacing: 2) { cell(urls, 2); cell(urls, 3) }
        }
        .background(Theme.hairline)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .aspectRatio(square ? 1 : nil, contentMode: .fit)
    }

    @ViewBuilder private func cell(_ urls: [URL], _ i: Int) -> some View {
        if i < urls.count { StoredImage(url: urls[i]) }
        else if !vibe.colors.isEmpty { Color(vibeHex: vibe.colors[i % vibe.colors.count].hex) }
        else { Theme.hairline }
    }
}

/// Large image on the left, two stacked on the right (vibe details).
struct VibeCollage: View {
    @Environment(VibeLibrary.self) private var library
    let vibe: SavedVibe

    var body: some View {
        let urls = vibe.imageFiles.map { library.imageURL(vibe, $0) }
        HStack(spacing: 2) {
            if let first = urls.first { StoredImage(url: first) }
            if urls.count > 1 {
                VStack(spacing: 2) {
                    StoredImage(url: urls[1])
                    if urls.count > 2 { StoredImage(url: urls[2]) }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .background(Theme.hairline)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .frame(height: 200)
    }
}

/// An image file shown filled and cropped, decoded at thumbnail size off the main thread.
struct StoredImage: View {
    let url: URL
    @State private var image: UIImage?

    var body: some View {
        Color.clear
            .overlay { if let image { Image(uiImage: image).resizable().scaledToFill() } }
            .clipped()
            .task(id: url) { image = await Task.detached { vibeThumbnail(url) }.value }
    }
}

/// Small overlapping-free dots for a card.
struct SwatchDots: View {
    let colors: [SavedVibe.Swatch]
    var size: CGFloat = 14

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(colors.prefix(4).enumerated()), id: \.offset) { _, c in
                Circle().fill(Color(vibeHex: c.hex)).frame(width: size, height: size)
                    .overlay(Circle().strokeBorder(Theme.ink.opacity(0.12)))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(colors.map(\.name).joined(separator: ", "))
    }
}

/// Rounded swatches with name (and hex), as on the review and details screens.
struct SwatchRow: View {
    let colors: [SavedVibe.Swatch]
    var showHex = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(Array(colors.prefix(4).enumerated()), id: \.offset) { _, c in
                VStack(alignment: .leading, spacing: 4) {
                    RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(vibeHex: c.hex))
                        .frame(height: 48)
                    Text(c.name).font(.forma(11)).foregroundStyle(Theme.ink).lineLimit(1)
                    if showHex { Text(c.hex.uppercased()).font(.forma(9)).foregroundStyle(Theme.muted) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(c.name) \(c.hex)")
            }
        }
    }
}

/// The editable profile, shared by the new-vibe review and vibe details. The common tags and instructions show first;
/// the finer tags and the long description are one tap deeper.
struct VibeFields: View {
    @Binding var vibe: SavedVibe
    @Binding var nameMissing: Bool
    var caption: String?
    @State private var more = false

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                NameField(text: $vibe.name, fieldID: "vibeName") {}
                    .onChange(of: vibe.name) { nameMissing = false }
                if nameMissing {
                    Text("Name it to save.").font(.forma(11)).foregroundStyle(Theme.terracotta)
                } else if let caption {
                    Text(caption).font(.forma(11)).foregroundStyle(Theme.muted)
                }
            }
            if !vibe.colors.isEmpty { SwatchRow(colors: vibe.colors) }
            TagEditor(title: "Styles", tags: $vibe.styles)
            TagEditor(title: "Mood", tags: $vibe.mood)
            TagEditor(title: "Materials", tags: $vibe.materials)
            TagEditor(title: "Avoid", tags: $vibe.avoid, avoid: true)
            if more {
                TagEditor(title: "Textures", tags: $vibe.textures)
                TagEditor(title: "Motifs", tags: $vibe.motifs)
                TagEditor(title: "Lighting", tags: $vibe.lighting)
                TagEditor(title: "Furniture", tags: $vibe.furnitureCharacteristics)
                VibeTextField(title: "Description", text: $vibe.description, prompt: "What this look is about")
            } else {
                Button { withAnimation(.spring(duration: 0.3, bounce: 0)) { more = true } } label: {
                    Label("More details", systemImage: "chevron.down").font(.forma(12)).foregroundStyle(Theme.wood)
                        .frame(minHeight: 44)
                }
                .accessibilityIdentifier("vibeMore")
            }
            VibeTextField(title: "Instructions", text: $vibe.customInstructions,
                          prompt: "Optional, e.g. keep the sofa, no dark colors")
        }
    }
}

/// Small caption over an outlined multi-line field.
private struct VibeTextField: View {
    let title: String
    @Binding var text: String
    let prompt: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.forma(10)).foregroundStyle(Theme.muted)
            TextField("", text: $text, prompt: Text(prompt).foregroundStyle(Theme.muted), axis: .vertical)
                .font(.forma(12)).foregroundStyle(Theme.ink).lineSpacing(4).lineLimit(2...14)
                .padding(14)
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.hairline))
        }
    }
}

/// Editable tag group: chips with an x, then a dashed "+ add" field. `avoid` tints terracotta.
struct TagEditor: View {
    let title: String?
    @Binding var tags: [String]
    var avoid = false
    @State private var entry = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title.uppercased()).font(.forma(10)).foregroundStyle(avoid ? Theme.terracotta : Theme.muted)
            }
            FlowLayout(spacing: 8) {
                ForEach(tags, id: \.self) { tag in
                    Button { tags.removeAll { $0 == tag } } label: {
                        HStack(spacing: 6) { Text(tag); Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                            .font(.forma(11)).foregroundStyle(avoid ? Theme.terracotta : Theme.ink)
                            .padding(.horizontal, 12).frame(minHeight: 32)
                            .background(avoid ? Theme.terracotta.opacity(0.14) : Theme.sand, in: Capsule())
                    }
                    .accessibilityLabel("Remove \(tag)")
                }
                TextField("", text: $entry, prompt: Text("+ add").foregroundStyle(Theme.muted))
                    .font(.forma(11)).foregroundStyle(Theme.ink)
                    .multilineTextAlignment(.center)
                    .frame(width: 64, height: 32)
                    .overlay(Capsule().strokeBorder(avoid ? Theme.terracotta : Theme.muted.opacity(0.6),
                                                    style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                    .submitLabel(.done).onSubmit(add)
            }
        }
    }

    private func add() {
        let tag = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        entry = ""
        if !tag.isEmpty, !tags.contains(tag) { tags.append(tag) }
    }
}

/// Wraps children onto new lines like text.
struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal.width ?? .infinity, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (view, origin) in zip(subviews, arrange(bounds.width, subviews).origins) {
            view.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(_ width: CGFloat, _ subviews: Subviews) -> (origins: [CGPoint], size: CGSize) {
        var origins: [CGPoint] = [], x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let s = view.sizeThatFits(.unspecified)
            if x > 0, x + s.width > width { x = 0; y += row + spacing; row = 0 }
            origins.append(CGPoint(x: x, y: y))
            x += s.width + spacing; row = max(row, s.height); widest = max(widest, x - spacing)
        }
        return (origins, CGSize(width: widest, height: y + row))
    }
}

extension Color {
    /// "#RRGGBB" -> Color; anything else -> gray.
    init(vibeHex hex: String) {
        let v = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0x808080
        self.init(red: Double(v >> 16 & 0xFF) / 255, green: Double(v >> 8 & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

/// A picked photo as JPEG, long edge <= 1024 px, quality 0.7: small enough for 15 in one request. nil if unreadable.
func resizedVibeJPEG(_ data: Data) -> Data? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
              kCGImageSourceCreateThumbnailFromImageAlways: true,
              kCGImageSourceCreateThumbnailWithTransform: true,
              kCGImageSourceThumbnailMaxPixelSize: 1024,
          ] as CFDictionary) else { return nil }
    return UIImage(cgImage: image).jpegData(compressionQuality: 0.7)
}

private func vibeThumbnail(_ url: URL) -> UIImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
              kCGImageSourceCreateThumbnailFromImageAlways: true,
              kCGImageSourceThumbnailMaxPixelSize: 400,
          ] as CFDictionary) else { return nil }
    return UIImage(cgImage: image)
}
