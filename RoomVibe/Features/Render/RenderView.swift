import CryptoKit
import SwiftUI

/// "Make it real": sends a Designer snapshot to /render and shows a before/after slider.
/// B presents this from the Designer: on tap, `guard let snap = captureDesignerSnapshot()`, then a sheet with
/// `RenderView(snapshot: snap, projectID:)`.
/// Vibe mode reuses its BeforeAfterSlider and calls APIClient.render directly.
struct RenderView: View {
    @State private var model: RenderModel
    @Environment(\.dismiss) private var dismiss
    @Environment(ProjectStore.self) private var store

    /// `camera`: the Designer camera at capture time. With it, a structure map of the same view is sent too,
    /// and a low camera starts in Photo mode.
    init(snapshot: UIImage, projectID: UUID? = nil, camera: RenderCamera? = nil, prompt: String = "", styleRef: UIImage? = nil) {
        _model = State(initialValue: RenderModel(snapshot: snapshot, projectID: projectID, camera: camera, prompt: prompt,
                                                 styleRef: styleRef))
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
                        // Vibe mode (VibeView) is parked for the MVP demo; it would go next to this picker.
                        Picker("View", selection: Binding(get: { model.view }, set: { model.view = $0 })) {
                            ForEach(RenderModel.View.allCases, id: \.self) { Text($0.title) }
                        }
                        .pickerStyle(.segmented)
                        .disabled(model.isLoading)
                    }
                    if let result = model.result {
                        ToolbarItem(placement: .primaryAction) {
                            ShareLink(item: Image(uiImage: result), preview: SharePreview("RoomVibe render", image: Image(uiImage: result)))
                        }
                    }
                }
        }
        .environment(\.colorScheme, .dark)
        .overlay {
            // The app's loading screen (sage square sliding around the ring, Paper colors) instead of a spinner.
            if model.isLoading {
                LoadingView(status: "Making it real… about 30 seconds")
                    .overlay(alignment: .topLeading) {
                        Button { dismiss() } label: {
                            Image(systemName: "xmark").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.ink)
                                .frame(width: 40, height: 40).background(Theme.tiles[0], in: Circle())
                        }
                        .accessibilityLabel("Close")
                        .padding(.leading, 16).padding(.top, 8)
                    }
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.25), value: model.isLoading)
        .onChange(of: model.view) { model.start() }
        .onAppear {
            guard model.result == nil, !model.isRunning else { return }
            if let project = store.projects.first(where: { $0.id == model.projectID }), let room = store.room(for: project) {
                model.setRoom(room, placements: project.placements, objects: store.objects)
            }
            model.start()
        }
        .onDisappear { model.cancel() }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .loading:
            Color.clear   // covered by the loading screen overlay in `body`
        case .done(let after, let isStale):
            VStack(spacing: 10) {
                BeforeAfterSlider(before: isStale ? model.staleBefore ?? model.snapshot : model.snapshot, after: after)
                if isStale {
                    Label("Offline: showing the last render of this room", systemImage: "clock.arrow.circlepath")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("Try again") { model.start() }.buttonStyle(.bordered)
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
                Button("Try again") { model.start() }.buttonStyle(.borderedProminent)
            }
            .foregroundStyle(.white)
        }
    }
}

@Observable
@MainActor
final class RenderModel {
    enum Phase { case loading, done(UIImage, isStale: Bool), failed(String) }

    /// Backend `view` modes: keep the dollhouse angle, or read as an eye-level interior photo.
    enum View: String, CaseIterable {
        case cutaway, interior
        var title: String { self == .cutaway ? "Dollhouse" : "Photo" }
    }

    let snapshot: UIImage
    let projectID: UUID?
    let prompt: String
    let styleRef: UIImage?
    let camera: RenderCamera?
    /// LayoutDescription of the room, filled in by RenderView before the first run.
    private(set) var layout = ""
    private var room: (model: RoomModel, placements: [Placement], objects: [ScannedObject])?
    /// Computed once on the first run; the same for both view modes.
    private var structure: StructureMap.Output?
    var view = View.cutaway
    private(set) var phase: Phase = .loading
    /// The snapshot the cached render was made from, so a stale slider compares the same room.
    private(set) var staleBefore: UIImage?

    init(snapshot: UIImage, projectID: UUID?, camera: RenderCamera? = nil, prompt: String, styleRef: UIImage?) {
        self.snapshot = snapshot.croppedToRenderAspect()
        self.projectID = projectID
        self.camera = camera
        // Camera looks down -Z: a forward vector close to horizontal reads as a photo, not a dollhouse.
        if let camera, abs(camera.transform.columns.2.y) < 0.4 { view = .interior }
        self.prompt = prompt
        self.styleRef = styleRef
        cacheKey = Self.cacheKey(prompt: prompt, styleRef: styleRef)
    }

    func setRoom(_ room: RoomModel, placements: [Placement], objects: [ScannedObject]) {
        self.room = (room, placements, objects)
        layout = LayoutDescription.text(room: room, placements: placements, objects: objects)
    }

    var isLoading: Bool { if case .loading = phase { true } else { false } }

    var result: UIImage? {
        if case .done(let image, _) = phase { image } else { nil }
    }

    /// Last successful render per room, view, style prompt and reference image; used when the network fails.
    private var cacheURL: URL? {
        guard let projectID else { return nil }
        return ProjectStore.projectDir(projectID).appending(path: "render-\(view.rawValue)\(cacheKey).jpg")
    }
    private let cacheKey: String

    private static func cacheKey(prompt: String, styleRef: UIImage?) -> String {
        var key = Data(prompt.utf8)
        if let ref = styleRef?.uploadJPEG() { key.append(ref) }
        return key.isEmpty ? "" : "-" + SHA256.hash(data: key).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private var beforeURL: URL? { cacheURL?.deletingPathExtension().appendingPathExtension("before.jpg") }

    private var task: Task<Void, Never>?
    private var generation = 0
    var isRunning: Bool { task != nil }

    /// Starts a render for the current view, cancelling any one in flight. Results of older requests are dropped.
    func start() {
        task?.cancel()
        task = Task { await run() }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    private func run() async {
        generation += 1
        let gen = generation
        defer { if gen == generation { task = nil } }
        // Capture everything the request depends on; the picker may change while it is in flight.
        let view = view, cacheURL = cacheURL, beforeURL = beforeURL
        phase = .loading
        do {
            if structure == nil, let camera, let room {
                // ~0.1–2.5 s of ray casting; keep it off the main actor.
                let job = Task.detached(priority: .userInitiated) {
                    StructureMap.render(room: room.model, placements: room.placements, objects: room.objects, camera: camera)
                }
                structure = await withTaskCancellationHandler { await job.value } onCancel: { job.cancel() }
            }
            try Task.checkCancellation()
            let fullLayout = [layout, structure?.legend ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
            let image = try await APIClient.shared.render(snapshot, prompt: prompt, layout: fullLayout, view: view.rawValue,
                                                        structure: structure?.image.croppedToRenderAspect(), styleRef: styleRef)
            if let cacheURL, let beforeURL {
                try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? image.jpegData(compressionQuality: 0.9)?.write(to: cacheURL, options: .atomic)
                try? snapshot.jpegData(compressionQuality: 0.8)?.write(to: beforeURL, options: .atomic)
            }
            guard gen == generation else { return }
            phase = .done(image, isStale: false)
        } catch {
            guard gen == generation, !Task.isCancelled else { return }
            if Self.isNetworkFailure(error), let cacheURL, let data = try? Data(contentsOf: cacheURL),
               let cached = UIImage(data: data) {
                staleBefore = beforeURL.flatMap { try? Data(contentsOf: $0) }.flatMap(UIImage.init(data:))
                phase = .done(cached, isStale: true)
            } else {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    /// Only these fall back to the cache; a server error is shown as is so it gets fixed, not hidden.
    private static func isNetworkFailure(_ error: Error) -> Bool {
        switch error as? APIError {
        case .offline, .timeout, .network: true
        default: false
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
