import SwiftUI

/// Inputs that tie a render to the scanned room and the Designer camera (`RenderModel.grounding`).
struct RenderGrounding {
    var layout: String
    var view: String
    var structure: UIImage?
    var products: [(name: String, image: UIImage)]
}

/// "Make it real": sends a Designer snapshot to /render and shows a before/after slider.
/// Presented as a sheet by `DesignerView.makeItReal()`, which captures the snapshot and camera before presenting.
/// Vibe mode reuses its BeforeAfterSlider and calls APIClient.render directly.
struct RenderView: View {
    @State private var model: RenderModel
    @Environment(\.dismiss) private var dismiss
    @Environment(ProjectStore.self) private var store
    @Environment(VibeLibrary.self) private var library
    @Environment(Connectivity.self) private var connectivity
    @State private var tab = Tab.compare

    /// Result tabs: the before/after slider, or the render alone.
    enum Tab: String, CaseIterable { case compare = "Compare", image = "Image" }

    /// `camera`: the Designer camera at capture time. With it, a structure map of the same view is sent too,
    /// and a low camera starts in Photo mode.
    init(snapshot: UIImage, projectID: UUID? = nil, camera: RenderCamera? = nil, prompt: String = "", styleRef: UIImage? = nil) {
        _model = State(initialValue: RenderModel(snapshot: snapshot, projectID: projectID, camera: camera, prompt: prompt,
                                                 styleRef: styleRef))
    }

    /// Next step after a render: restyle this view and shop real stores, starting from the room's vibe if it has one.
    private var shopLink: some View {
        let vibe = store.projects.first { $0.id == model.projectID }?.vibeID.flatMap(library.vibe)
        return NavigationLink {
            VibeView(snapshot: model.snapshot, projectID: model.projectID, grounding: { [model] in await model.grounding() })
        } label: {
            Label(vibe.map { "Shop \($0.name)" } ?? "Shop a vibe", systemImage: "sparkles").lineLimit(1)
        }
        .buttonStyle(PillButtonStyle(filled: false))
        .accessibilityIdentifier("openVibe")
    }

    var body: some View {
        NavigationStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.ground.ignoresSafeArea())
                .safeAreaInset(edge: .bottom) {
                    if !model.isLoading {   // also after a failed render: shopping only needs the snapshot
                        VStack(spacing: 10) {
                            shopLink
                            if model.result != nil { TabPicker(selection: $tab) }
                        }
                        .padding(.horizontal, 24).padding(.bottom, 8)
                    }
                }
                .navigationTitle("Make it real")
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(Theme.ground, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        Text("Make it real").font(.forma(14, bold: true)).foregroundStyle(Theme.ink)
                    }
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { dismiss() }.font(.forma(13)).foregroundStyle(Theme.ink)
                    }
                    if model.result != nil, !model.isRunning {
                        ToolbarItem(placement: .primaryAction) {
                            Button { model.start() } label: { Image(systemName: "arrow.clockwise") }
                                .foregroundStyle(Theme.ink)
                                .accessibilityLabel("Render again")
                        }
                    }
                    if let result = model.result {
                        ToolbarItem(placement: .primaryAction) {
                            ShareLink(item: Image(uiImage: result), preview: SharePreview("RoomVibe render", image: Image(uiImage: result)))
                                .foregroundStyle(Theme.ink)
                        }
                    }
                }
        }
        .environment(\.colorScheme, .light)   // Paper is light-only
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
        // Back online after an offline failure or a cached render: try again without a tap.
        .onChange(of: connectivity.online) { _, online in
            if online, model.needsRetry { model.start() }
        }
        .onAppear {
            model.onFilesChanged = { [store] in store.filesChanged() }
            guard model.result == nil, !model.isRunning else { return }
            if let project = store.projects.first(where: { $0.id == model.projectID }), let room = store.room(for: project) {
                model.setRoom(project: project, room: room, objects: store.objects)
            }
            // The room's last render shows right away; ↻ (toolbar) renders this view again.
            if !model.showSaved() { model.start() }
        }
        .onDisappear { model.cancel() }
        .sensoryFeedback(trigger: model.result != nil) { _, done in done ? .success : nil }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .loading:
            Color.clear   // covered by the loading screen overlay in `body`
        case .done(let after, let isStale):
            switch tab {
            case .image:
                Image(uiImage: after).resizable().scaledToFit().padding(.vertical)
                    .accessibilityLabel("Render")
            case .compare:
                VStack(spacing: 14) {
                    Spacer(minLength: 0)
                    BeforeAfterSlider(before: model.savedBefore ?? model.snapshot, after: after)
                    if isStale {
                        Label("Offline · showing the last render of this room", systemImage: "clock.arrow.circlepath")
                            .font(.forma(11)).foregroundStyle(Theme.muted)
                        Button("Try again") { model.start() }
                            .buttonStyle(PillButtonStyle(filled: false))
                            .frame(maxWidth: 200)
                    } else if let at = model.savedAt {
                        Text("Last render · \(at.formatted(.relative(presentation: .named))) · ↻ to redo")
                            .font(.forma(11)).foregroundStyle(Theme.muted)
                    } else {
                        Text("Drag the divider to compare").font(.forma(11)).foregroundStyle(Theme.muted)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical)
            }
        case .failed(let message):
            VStack(spacing: 12) {
                Image(systemName: "wifi.exclamationmark").font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(Theme.sageDeep)
                Text("Couldn't render").font(.forma(18, bold: true)).foregroundStyle(Theme.ink)
                Text(message).font(.forma(12)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                Button("Try again") { model.start() }
                    .buttonStyle(PillButtonStyle())
                    .frame(maxWidth: 200)
                    .padding(.top, 8)
            }
            .padding(.horizontal, 32)
        }
    }
}

/// Compare / Image switch: sage pill on the chosen side, ink outline around both.
private struct TabPicker: View {
    @Binding var selection: RenderView.Tab

    var body: some View {
        HStack(spacing: 0) {
            ForEach(RenderView.Tab.allCases, id: \.self) { view in
                let on = view == selection
                Button { selection = view } label: {
                    Text(view.rawValue).font(.forma(13, bold: on))
                        .foregroundStyle(on ? Theme.onSage : Theme.ink)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background(on ? Theme.sage : .clear, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(4)
        .overlay(Capsule().strokeBorder(Theme.ink, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Result view")
        .animation(.spring(duration: 0.25, bounce: 0), value: selection)
        .sensoryFeedback(.selection, trigger: selection)
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
    private var standIns: Set<UUID> = []
    private var finishes = ""
    /// Shopped placements in the room (RenderInputs.scene); the first 3 with a photo become product 1, 2, 3.
    private var shopped: [(id: UUID, product: ShopProduct)] = []
    /// The numbered products. Fixed on the first run (after any downloads), like `structure`: the layout, the
    /// map and the upload must agree on what product N is, so a photo that arrives later isn't added.
    private var products: [(id: UUID, name: String, image: UIImage)]?
    /// Computed once on the first run; the same for both view modes.
    private var structure: StructureMap.Output?
    var view = View.cutaway
    private(set) var phase: Phase = .loading
    /// Snapshot the shown saved render was made from (reopened last render or offline fallback), else nil.
    private(set) var savedBefore: UIImage?
    /// When the shown saved render was made; nil once a fresh one is shown.
    private(set) var savedAt: Date?
    /// Called after the render cache is written or pruned: those files live in the room's folder, outside the
    /// store, so sync would otherwise not see them until the next unrelated change. Set by RenderView.
    @ObservationIgnored var onFilesChanged: (() -> Void)?

    /// Shows the room's last render, if any. Returns false when there is none.
    func showSaved() -> Bool {
        guard let cacheURL, let data = try? Data(contentsOf: cacheURL), let image = UIImage(data: data) else { return false }
        savedBefore = beforeURL.flatMap { try? Data(contentsOf: $0) }.flatMap(UIImage.init(data:))
        savedAt = (try? FileManager.default.attributesOfItem(atPath: cacheURL.path(percentEncoded: false)))?[.modificationDate] as? Date
        phase = .done(image, isStale: false)
        return true
    }

    init(snapshot: UIImage, projectID: UUID?, camera: RenderCamera? = nil, prompt: String, styleRef: UIImage?) {
        self.snapshot = snapshot.croppedToRenderAspect()
        self.projectID = projectID
        self.camera = camera
        // Camera looks down -Z: a forward vector close to horizontal reads as a photo, not a dollhouse.
        if let camera, abs(camera.transform.columns.2.y) < 0.4 { view = .interior }
        self.prompt = prompt
        self.styleRef = styleRef
    }

    /// Describes the room as the Designer shows it (RenderInputs.scene).
    func setRoom(project: Project, room: RoomModel, objects: [ScannedObject]) {
        let s = RenderInputs.scene(project: project, room: room, objects: objects)
        self.room = (s.room, s.placements, s.objects)
        standIns = s.standIns
        finishes = RenderInputs.finishes(project)
        shopped = s.shopped
        products = nil
        structure = nil   // drawn with the product colors
        layout = describe(products: [])
    }

    private func describe(products: [UUID]) -> String {
        guard let room else { return "" }
        return LayoutDescription.text(room: room.model, placements: room.placements, objects: room.objects,
                                      finishes: finishes, standIns: standIns, products: products)
    }

    /// Product photos (ProductPhotos), fetching missing ones in parallel (≤ ~10 s), then numbers the first 3 that
    /// loaded; the layout is rebuilt with those numbers.
    private func loadProducts() async {
        guard products == nil, let projectID else { return }
        let shopped = shopped
        await withTaskGroup(of: Void.self) { group in
            for s in shopped { group.addTask { await ProductPhotos.cache(s.product, placement: s.id, project: projectID) } }
        }
        guard !Task.isCancelled else { return }
        let loaded = shopped.compactMap { s in
            ProductPhotos.load(placement: s.id, project: projectID).map { (s.id, String(s.product.title.prefix(60)), $0) }
        }
        products = Array(loaded.prefix(StructureMap.Kind.products.count))
        layout = describe(products: products?.map(\.id) ?? [])
    }


    /// What keeps a render of this view on the scan: the layout text (with product numbers and the map's legend),
    /// the structure map from the Designer camera, the view mode and the product photos. Built once, then reused by
    /// Make it real and by the vibe restyle of the same view.
    func grounding(view: View? = nil) async -> RenderGrounding {
        await loadProducts()   // before the structure map: it colors the products the layout numbers
        let products = products ?? []
        if structure == nil, let camera, let room, !Task.isCancelled {
            // ~0.1–2.5 s of ray casting; keep it off the main actor.
            let job = Task.detached(priority: .userInitiated) {
                StructureMap.render(room: room.model, placements: room.placements, objects: room.objects, camera: camera,
                                    products: products.map(\.id))
            }
            structure = await withTaskCancellationHandler { await job.value } onCancel: { job.cancel() }
        }
        return RenderGrounding(layout: [layout, structure?.legend ?? ""].filter { !$0.isEmpty }.joined(separator: " "),
                               view: (view ?? self.view).rawValue, structure: structure?.image.croppedToRenderAspect(),
                               products: products.map { ($0.name, $0.image) })
    }

    var isLoading: Bool { if case .loading = phase { true } else { false } }

    /// A failed run or a cached (stale) render: worth retrying once the network is back.
    var needsRetry: Bool {
        switch phase {
        case .failed, .done(_, isStale: true): !isRunning
        default: false
        }
    }

    var result: UIImage? {
        if case .done(let image, _) = phase { image } else { nil }
    }

    /// The room's most recent render (one per room, overwritten each time): reopened instantly, and the offline fallback.
    private var cacheURL: URL? {
        guard let projectID, prompt.isEmpty, styleRef == nil else { return nil }   // style variants aren't "the room"
        return ProjectStore.projectDir(projectID).appending(path: "render-latest.jpg")
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
            let g = await grounding(view: view)
            try Task.checkCancellation()
            let image = try await APIClient.shared.render(snapshot, prompt: prompt, layout: g.layout, view: g.view,
                                                        structure: g.structure, styleRef: styleRef, products: g.products)
            if let cacheURL, let beforeURL {
                let dir = cacheURL.deletingLastPathComponent()
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try? image.jpegData(compressionQuality: 0.9)?.write(to: cacheURL, options: .atomic)
                try? snapshot.jpegData(compressionQuality: 0.8)?.write(to: beforeURL, options: .atomic)
                // Only the latest is kept: drop older per-view / per-style caches from earlier builds.
                for f in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
                where f.lastPathComponent.hasPrefix("render-") && !f.lastPathComponent.hasPrefix("render-latest") {
                    try? FileManager.default.removeItem(at: f)
                }
                onFilesChanged?()
            }
            guard gen == generation else { return }
            savedBefore = nil
            savedAt = nil
            phase = .done(image, isStale: false)
        } catch {
            guard gen == generation, !Task.isCancelled else { return }
            if Self.isNetworkFailure(error), let cacheURL, let data = try? Data(contentsOf: cacheURL),
               let cached = UIImage(data: data) {
                savedBefore = beforeURL.flatMap { try? Data(contentsOf: $0) }.flatMap(UIImage.init(data:))
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
        Text(text).font(.forma(11, bold: true)).padding(.horizontal, 8).padding(.vertical, 4)
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
