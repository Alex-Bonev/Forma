import SwiftUI

/// "Make it real": sends a Designer snapshot to /render and shows a before/after slider.
/// B presents this from the Designer: on tap, `captureDesignerSnapshot()`, then a sheet with
/// `RenderView(snapshot:projectID:)`.
/// Vibe mode reuses it with a style prompt and the inspiration image.
struct RenderView: View {
    @State private var model: RenderModel
    @Environment(\.dismiss) private var dismiss

    init(snapshot: UIImage, projectID: UUID? = nil, prompt: String = "", styleRef: UIImage? = nil) {
        _model = State(initialValue: RenderModel(snapshot: snapshot, projectID: projectID, prompt: prompt, styleRef: styleRef))
    }

    var body: some View {
        NavigationStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
                .navigationTitle("Make it real")
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(.visible, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                    ToolbarItem(placement: .bottomBar) {
                        NavigationLink {
                            VibeView(snapshot: model.snapshot, projectID: model.projectID)
                        } label: {
                            Label("Match a vibe from a photo", systemImage: "sparkles").labelStyle(.titleAndIcon)
                        }
                    }
                    if let result = model.result {
                        ToolbarItem(placement: .primaryAction) {
                            ShareLink(item: Image(uiImage: result), preview: SharePreview("RoomVibe render", image: Image(uiImage: result)))
                        }
                    }
                }
        }
        .environment(\.colorScheme, .dark)
        .task { if model.result == nil { await model.run() } }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .loading:
            Image(uiImage: model.snapshot)
                .resizable().scaledToFit()
                .blur(radius: 6).opacity(0.6)
                .overlay {
                    VStack(spacing: 12) {
                        ProgressView().controlSize(.large).tint(.white)
                        Text("Making it real… about 30 seconds").font(.headline).foregroundStyle(.white)
                    }
                }
        case .done(let after, let isStale):
            VStack(spacing: 10) {
                BeforeAfterSlider(before: model.snapshot, after: after)
                if isStale {
                    Label("Offline: showing the last render of this room", systemImage: "clock.arrow.circlepath")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("Try again") { Task { await model.run() } }.buttonStyle(.bordered)
                } else {
                    Text("Drag the divider to compare").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding(.bottom)
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't render", systemImage: "wifi.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                Button("Try again") { Task { await model.run() } }.buttonStyle(.borderedProminent)
            }
            .foregroundStyle(.white)
        }
    }
}

@Observable
@MainActor
final class RenderModel {
    enum Phase { case loading, done(UIImage, isStale: Bool), failed(String) }

    let snapshot: UIImage
    let projectID: UUID?
    let prompt: String
    let styleRef: UIImage?
    private(set) var phase: Phase = .loading

    init(snapshot: UIImage, projectID: UUID?, prompt: String, styleRef: UIImage?) {
        self.snapshot = snapshot.croppedToRenderAspect()
        self.projectID = projectID
        self.prompt = prompt
        self.styleRef = styleRef
    }

    var result: UIImage? {
        if case .done(let image, _) = phase { image } else { nil }
    }

    /// Last successful render per room (and per style), used when the network fails.
    private var cacheURL: URL? {
        guard let projectID else { return nil }
        let hash = prompt.utf8.reduce(UInt64(5381)) { $0 &* 33 &+ UInt64($1) }   // stable across launches
        let name = prompt.isEmpty ? "render.jpg" : "render-\(hash % 1_000_000).jpg"
        return ProjectStore.projectDir(projectID).appending(path: name)
    }

    func run() async {
        phase = .loading
        do {
            let image = try await APIClient.shared.render(snapshot, prompt: prompt, styleRef: styleRef)
            if let cacheURL { try? image.jpegData(compressionQuality: 0.9)?.write(to: cacheURL, options: .atomic) }
            phase = .done(image, isStale: false)
        } catch {
            if let cacheURL, let data = try? Data(contentsOf: cacheURL), let cached = UIImage(data: data) {
                phase = .done(cached, isStale: true)
            } else {
                phase = .failed(error.localizedDescription)
            }
        }
    }
}

/// Render on the right, snapshot on the left of a draggable divider.
struct BeforeAfterSlider: View {
    let before: UIImage
    let after: UIImage
    @State private var split: CGFloat = 0.5

    var body: some View {
        GeometryReader { geo in
            let x = geo.size.width * split
            ZStack(alignment: .leading) {
                fill(after, geo.size)
                fill(before, geo.size)
                    .mask(alignment: .leading) { Rectangle().frame(width: x) }
                Rectangle().fill(.white).frame(width: 2).offset(x: x - 1)
                Image(systemName: "chevron.left.chevron.right")
                    .font(.footnote.weight(.bold))
                    .padding(10)
                    .background(.white, in: Circle())
                    .foregroundStyle(.black)
                    .offset(x: x - 18)
                tag("Before").frame(maxHeight: .infinity, alignment: .top).padding(10).opacity(split > 0.15 ? 1 : 0)
                tag("After").frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(10)
                    .opacity(split < 0.85 ? 1 : 0)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                split = min(max(v.location.x / max(geo.size.width, 1), 0), 1)
            })
            .accessibilityElement()
            .accessibilityLabel("Before and after comparison")
            .accessibilityValue("\(Int(split * 100)) percent before")
            .accessibilityAdjustableAction { dir in
                split = min(max(split + (dir == .increment ? 0.1 : -0.1), 0), 1)
            }
        }
        .aspectRatio(after.size.width / max(after.size.height, 1), contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
        .sensoryFeedback(.selection, trigger: split == 0 || split == 1)
    }

    private func fill(_ image: UIImage, _ size: CGSize) -> some View {
        Image(uiImage: image).resizable().scaledToFill().frame(width: size.width, height: size.height).clipped()
    }

    private func tag(_ text: String) -> some View {
        Text(text).font(.caption.weight(.semibold)).padding(.horizontal, 8).padding(.vertical, 4)
            .background(.ultraThinMaterial, in: Capsule())
    }
}

extension UIImage {
    /// Center-crop to the aspect /render outputs (2:3, 1:1 or 3:2, same rule as backend `output_size`),
    /// so the before/after slider lines up pixel for pixel.
    func croppedToRenderAspect() -> UIImage {
        guard let cg = cgImage else { return self }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let aspect: CGFloat = h > w * 1.2 ? 2.0 / 3 : w > h * 1.2 ? 3.0 / 2 : 1
        let crop = w / h > aspect
            ? CGRect(x: ((w - h * aspect) / 2).rounded(), y: 0, width: (h * aspect).rounded(), height: h)
            : CGRect(x: 0, y: ((h - w / aspect) / 2).rounded(), width: w, height: (w / aspect).rounded())
        return cg.cropping(to: crop).map { UIImage(cgImage: $0, scale: scale, orientation: imageOrientation) } ?? self
    }
}
