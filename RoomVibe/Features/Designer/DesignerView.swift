import SwiftUI
import RealityKit
/// Core demo screen: orbit the dollhouse, drop library objects in, drag/rotate/delete them.
///
/// Touch model (all on `TouchSurface`):
/// - one finger on an object: slide it on the floor · one finger elsewhere: orbit (flick for momentum)
/// - two fingers: pan · pinch: zoom · twist: rotate the selected object (or the view if none)
/// - tap: select (when nothing is selected) · tap empty space: deselect · long-press an object: select it
/// - with a placement selected, a one-finger drag that starts on any object moves the selected one (never switches)
struct DesignerView: View {
    /// `.card` is the small orbit-and-zoom preview on Room detail (no editing); `.full` is the editor.
    enum Style { case full, card }
    let projectID: UUID
    var style: Style = .full
    /// Card only: the expand button.
    var onExpand: (() -> Void)? = nil
    /// Full only: open the Add Item catalog as soon as the editor appears (Room detail's "+ Add object").
    var opensCatalog = false
    @Environment(ProjectStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var showObjects = false
    @State private var objectsDetent = ObjectsDetent.medium   // bottom sheet height: peek / medium / large (Paper E2a, E2, E2b)
    @GestureState private var objectsDrag: CGFloat = 0
    @State private var hiddenPlacements: Set<UUID> = []   // eye toggle in the Objects panel; not persisted
    @State private var scene = Entity()
    @State private var camera = OrbitCamera()
    @State private var walls = WallCutaway()
    @State private var roomEntity: Entity?
    @State private var roomSize: SIMD2<Float> = .zero
    @State private var touched = false   // camera moved since open: no thumbnail from this visit
    @State private var outline: [SIMD3<Float>]?   // scanned floor polygon, room coordinates (cached: room(for:) reads disk)
    @State private var placed: [UUID: Entity] = [:]   // placement id -> entity
    @State private var selected: UUID?
    @State private var selectedRoomObject: Int?   // index into the scan's RoomPlan objects
    @State private var highlighted: Entity?
    @State private var showCatalog = false
    @State private var showCart = false
    @State private var showAddChoice = false   // Add object: scan a physical object, or select a preset
    @State private var editing: UUID?   // placement open in the Size sheet; not tied to `selected`, which taps can change
    @State private var showPhotos = false
    @State private var scanTarget: ScanTarget?
    @State private var undo: (title: String, snapshot: Project)?   // last Delete / Hide, offered for a few seconds
    @State private var naturalSize: [UUID: SIMD3<Float>] = [:]   // placement id -> unscaled model size (m)
    @State private var making3D: (id: UUID, task: Task<Void, Never>)?   // "Make it 3D" job for a shopped product
    @State private var failed3D: Set<UUID> = []

    /// What a new Object Capture scan should replace.
    enum ScanTarget: Identifiable {
        /// `new`: a fresh scan from Add object, dropped where the user is looking.
        case placement(UUID), roomObject(Int), new
        var id: String {
            switch self { case .placement(let u): u.uuidString; case .roomObject(let i): "room-\(i)"; case .new: "new" }
        }
    }
    @AppStorage(RoomBuilder.realisticKey) private var realisticFurniture = true
    @State private var moving: (id: UUID, offset: SIMD3<Float>)?
    @State private var viewSize: CGSize = .zero
    @State private var lowWalls = false
    @State private var showHint = true
    @State private var adding: String?
    @State private var twistingObject = false
    @State private var objectHint = false
    @State private var lifts = 0   // haptic trigger
    // Kept for picking: RealityKit's own ray(through:) matches its real render surface, which is taller than the
    // SwiftUI frame (it extends under the bottom panel), so hand-rolled projection from the frame missed objects.
    @State private var content: RealityViewCameraContent?

    private var project: Project? { store.projects.first { $0.id == projectID } }

    /// Light walls get a dark palette backdrop and vice versa.
    private var lightBackdrop: Bool { backdrop == Theme.ground }
    private var chrome: (fill: Color, ink: Color) { Tone.chrome(on: backdrop) }
    private var backdrop: Color { Tone.backdrop(subjectLuminance: Finish.wall(project?.wallFinish).luminance) }

    /// Designer snapshot handed to the photoreal render sheet.
    private struct RenderShot: Identifiable {
        let id = UUID()
        let image: UIImage
        let camera: RenderCamera
    }
    @State private var renderShot: RenderShot?
    @State private var lockMenuFor: UUID?   // placement whose Lock pill is showing

    private func renderCamera() -> RenderCamera {
        RenderCamera(transform: camera.entity.transformMatrix(relativeTo: nil),
                     verticalFOV: camera.entity.camera.fieldOfViewInDegrees,
                     viewSize: viewSize, wallScale: lowWalls ? 0.3 : 1)
    }

    /// Make it real from exactly this view. Capture before presenting: the snapshot and the camera must describe the
    /// same frame. Selection markers are cleared first so the image model doesn't render them as objects.
    private func makeItReal() {
        guard renderShot == nil else { return }   // a second tap would replace the sheet mid-presentation
        touched = true   // no thumbnail capture racing this snapshot and the sheet
        if selected != nil || selectedRoomObject != nil {
            selected = nil
            selectedRoomObject = nil
            Task {
                try? await Task.sleep(for: .milliseconds(150))   // let RealityKit draw a frame without the marker
                makeItReal()
            }
            return
        }
        guard let image = captureDesignerSnapshot(size: viewSize) else { return }
        renderShot = RenderShot(image: image, camera: renderCamera())
    }

    var body: some View {
        stack.sheet(item: $renderShot) { shot in
            RenderView(snapshot: shot.image, projectID: projectID, camera: shot.camera)
        }
        .onDisappear { making3D?.task.cancel() }
    }

    @ViewBuilder private var stack: some View {
        if let project, let room = store.room(for: project), style == .card {
            realityView(project: project, room: room)
                .overlay(alignment: .topTrailing) {
                    HStack(spacing: 8) {
                        Button { onExpand?() } label: {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.ink)
                                .frame(width: 44, height: 44)
                                .background(Theme.ground.opacity(0.85), in: Circle())
                        }
                        .accessibilityLabel("Fullscreen")
                    }
                    .padding(12)
                }
                .overlay(alignment: .bottom) { HintPill("Drag to orbit · Pinch to zoom").padding(.bottom, 12) }
                .onChange(of: realisticFurniture) { rebuildRoom(room) }
        } else if let project, let room = store.room(for: project) {
            realityView(project: project, room: room)
                .padding(.bottom, showObjects ? min(objectsHeight(), ObjectsDetent.medium.height(in: viewSize.height)) : 0)   // room recenters above the Objects sheet (Paper E2/E3)
                .toolbar(.hidden, for: .navigationBar)
                .onAppear {
                    if opensCatalog { showAddChoice = true }
                }
                .onChange(of: lowWalls) { rebuildRoom(room) }
                .onChange(of: realisticFurniture) { rebuildRoom(room) }
                .onChange(of: selected) { _, new in
                    if new != nil { undo = nil; selectedRoomObject = nil; showObjects = true }
                    if new != editing { editing = nil }   // the Size sheet edits one item; selecting another closes it
                    highlight(new.flatMap { placed[$0] })
                }
                .onChange(of: selectedRoomObject) { _, new in
                    if new != nil { undo = nil; selected = nil; showObjects = true }
                    highlight(new.flatMap(roomObjectEntity))
                }
                .sheet(isPresented: $showCatalog) { catalogSheet }
                .sheet(isPresented: $showAddChoice) { addChoiceSheet }
                .sheet(isPresented: $showCart) { CartSheet(projectID: projectID) }
                .sheet(isPresented: $showPhotos) { RoomPhotosView(projectID: projectID) }
                .sheet(isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
                    if let editing { editor(editing) }
                }
                .fullScreenCover(item: $scanTarget) { target in
                    ObjectScanView { object in Task { await applyScan(object, to: target) } }
                }
                .overlay(alignment: .top) { topChrome(project).padding(.horizontal, 16).padding(.top, 8) }
                .overlay(alignment: .topLeading) {
                    // Under the back button (Paper E): the room's vibe. Make it real is the wide bar at the bottom.
                    RoomVibeControl(projectID: projectID, fill: lightBackdrop ? Theme.wood : Theme.sand,
                                    ink: lightBackdrop ? Theme.ground : Theme.ink) { EmptyView() }
                    .padding(.leading, 16).padding(.top, 8 + 44 + 12)
                }
                .overlay(alignment: .bottom) {
                    if showObjects { objectsPanel(project).transition(.move(edge: .bottom).combined(with: .opacity)) }
                }
                .animation(.spring(duration: 0.35, bounce: 0), value: showObjects)
                .animation(.spring(duration: 0.3, bounce: 0), value: objectsDetent)
                .animation(.spring(duration: 0.3, bounce: 0), value: undo?.title)
                .overlay(alignment: .bottom) {
                    VStack(spacing: 12) {
                        // With the Objects panel open, Undo lives in the panel instead of under it.
                        if !showObjects { undoBar }
                        hint.allowsHitTesting(false)
                        // Renders exactly what's on screen: frame it by dragging, then tap.
                        if !showObjects {
                            HStack(spacing: 10) {
                                MakeItRealButton(wide: true, fill: lightBackdrop ? Theme.wood : Theme.sand,
                                                 ink: lightBackdrop ? Theme.ground : Theme.ink,
                                                 sparkle: lightBackdrop ? Theme.sage : Theme.sageDeep, action: makeItReal)
                                AddObjectButton(fill: lightBackdrop ? Theme.wood : Theme.sand,
                                                ink: lightBackdrop ? Theme.ground : Theme.ink) { showAddChoice = true }
                                let ink = lightBackdrop ? Theme.ground : Theme.ink
                                let cartCount = RoomCart.count(in: store.projects, room: projectID)
                                if cartCount > 0 {
                                    CartButton(count: cartCount, size: 56, fill: lightBackdrop ? Theme.wood : Theme.sand,
                                               ink: ink, stroke: ink.opacity(0.35), lineWidth: 1.5) { showCart = true }
                                }
                            }
                            .lineLimit(1).minimumScaleFactor(0.7)   // Make it real shrinks, never drops its label, when the cart button takes room
                            .padding(.horizontal, 16)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                    .padding(.bottom, 24)
                }
                .overlay(alignment: .bottomLeading) {
                    lockMenu().padding(.leading, 16).padding(.bottom, showObjects ? objectsHeight(drag: objectsDrag) + 12 : 36)   // rides the Objects sheet's top edge
                        .animation(.spring(duration: 0.25, bounce: 0), value: lockMenuFor)   // scoped: on the whole view it froze the Designer
                }
                .sensoryFeedback(.selection, trigger: selected)
        } else {
            ContentUnavailableView("Room not found", systemImage: "cube.transparent")
        }
    }

    private func realityView(project: Project, room: RoomModel) -> some View {
        RealityView { content in
            content.camera = .virtual
            self.content = content
            let sun = DirectionalLight()
            sun.light.intensity = 3000
            sun.shadow = DirectionalLightComponent.Shadow()
            sun.look(at: .zero, from: [2, 5, 3], relativeTo: nil)
            scene.addChild(sun)
            scene.addChild(camera.entity)
            content.add(scene)
            rebuildRoom(room)
            let w = walls
            camera.onFrame = { w.update(cameraPosition: $0) }
            camera.configure(roomSize: roomSize)
            let cam = camera
            camera.updates = content.subscribe(to: SceneEvents.Update.self) { [weak cam] e in
                MainActor.assumeIsolated { cam?.update(dt: Float(e.deltaTime)) }
            }
            // Show the room right away; large scans stream in after.
            Task { for p in project.placements { await spawn(p) } }
        }
        .ignoresSafeArea(edges: style == .card ? [] : .bottom)
        .background { if style == .full { backdrop.ignoresSafeArea() } }
        .onChange(of: project.placements.map(\.id)) { spawnShoppedProducts() }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { viewSize = $0 }
        .overlay {
            TouchSurface(handlers: style == .card ? cardHandlers : touchHandlers, accessibilityValue: selectionDescription(project))
                .ignoresSafeArea(edges: style == .card ? [] : .bottom)
        }
        .overlay(alignment: .topTrailing) {
            if style == .full { viewControls.padding(.horizontal, 16).padding(.top, 64) }
        }
        .animation(.easeOut(duration: 0.3), value: showHint)
        .animation(.easeOut(duration: 0.3), value: objectHint)
        .sensoryFeedback(.impact(weight: .light), trigger: lifts)
    }

    /// Maps-style floating controls.
    private var viewControls: some View {
        VStack(spacing: 0) {
            controlButton("scope", label: "Reset view") { camera.reset() }
            if !RoomPhotos.photoURLs(projectDir: ProjectStore.projectDir(projectID)).isEmpty {
                Divider().frame(width: 28)
                controlButton("photo.on.rectangle", label: "Room photos") { showPhotos = true }
            }
            Divider().frame(width: 28)
            finishesMenu
            Divider().frame(width: 28)
            controlButton(lowWalls ? "square.split.bottomrightquarter.fill" : "square.split.bottomrightquarter",
                          label: lowWalls ? "Full walls" : "Cutaway walls") { lowWalls.toggle() }
        }
        .foregroundStyle(chrome.ink)
        .background(chrome.fill, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    /// Wall and floor finish presets, saved per room.
    private var finishesMenu: some View {
        Menu {
            Picker("Walls", selection: finishBinding(\.wallFinish, default: Finish.walls[0].id)) {
                ForEach(Finish.walls) { Text($0.name).tag($0.id) }
            }
            .pickerStyle(.inline)
            Picker("Floor", selection: finishBinding(\.floorFinish, default: Finish.floors[0].id)) {
                ForEach(Finish.floors) { Text($0.name).tag($0.id) }
            }
            .pickerStyle(.inline)
            Toggle("Realistic Models", systemImage: "sparkles", isOn: $realisticFurniture)
        } label: {
            Image(systemName: "paintbrush").font(.system(size: 17, weight: .medium)).frame(width: 44, height: 44)
        }
        .accessibilityLabel("Finishes")
    }

    private var nameBinding: Binding<String> {
        Binding(get: { project?.name ?? "" }, set: { name in
            // Don't trim while typing: the field re-reads the name, so a trimmed trailing space would vanish.
            guard var p = project, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            undo = nil
            p.name = name
            store.update(p)
        })
    }

    private func finishBinding(_ key: WritableKeyPath<Project, String?>, default d: String) -> Binding<String> {
        Binding(
            get: { project?[keyPath: key] ?? d },
            set: { id in
                guard var p = project, let room = roomEntity else { return }
                undo = nil   // undo restores a whole snapshot; any other edit ends its window
                p[keyPath: key] = id
                store.update(p)
                let wall = Finish.wall(p.wallFinish), floor = Finish.floor(p.floorFinish)
                Task { await Finish.apply(to: room, wall: wall, floor: floor) }
            })
    }

    private func controlButton(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 17, weight: .medium)).frame(width: 44, height: 44)
        }
        .accessibilityLabel(label)
    }

    /// VoiceOver (and UI tests) read the selected object's saved position.
    private func selectionDescription(_ project: Project) -> String? {
        guard let selected, let p = project.placements.first(where: { $0.id == selected }), let name = name(of: selected)
        else { return nil }
        return String(format: "%@ at %.2f, %.2f m", name, p.position.x, p.position.z)
    }

    private func name(of id: UUID) -> String? {
        guard let p = project?.placements.first(where: { $0.id == id }) else { return nil }
        return CatalogItem.item(p.catalogItem)?.name ?? store.objects.first { $0.id == p.objectID }?.name
    }

    // MARK: Touch

    private var touchHandlers: TouchSurface.Handlers {
        var h = TouchSurface.Handlers()
        h.touchDown = {
            touched = true
            camera.grab()
            lockMenuFor = nil   // the menu belongs to a tap on the item; any new touch hides it
            if showHint { showHint = false }
        }
        h.touchUp = { camera.release() }
        h.oneFinger = { phase, location, delta, velocity in
            switch phase {
            case .began:
                if let id = dragTarget(at: location), let e = placed[id], let start = floorPoint(at: location) {
                    moving = (id, e.position - start)
                    selected = id
                    e.scale = baseScale(id) * 1.04   // lifted while dragged
                    lifts += 1
                    objectHint = false
                }
            case .changed:
                if let moving, let e = placed[moving.id] {
                    if let p = floorPoint(at: location) { e.position = clamp(p + moving.offset, keeping: e) }
                } else {
                    camera.orbit(by: delta)
                }
            case .ended:
                if let moving {
                    placed[moving.id]?.scale = baseScale(moving.id)
                    self.moving = nil
                    commit()
                } else {
                    camera.endOrbit(velocity: velocity)
                }
            }
        }
        h.twoFingerPan = { delta in
            if moving == nil && !twistingObject { camera.pan(by: delta, viewHeight: viewSize.height) }
        }
        h.pinch = { phase, scale in
            if twistingObject { return }   // rotating an object shouldn't also zoom
            switch phase {
            case .began: camera.beginZoom()
            case .changed: camera.zoom(scale: scale)
            case .ended: break
            }
        }
        h.twist = { phase, delta in
            if phase == .began { twistingObject = selected.map { !isLocked($0) } ?? false }
            if twistingObject, let selected, let e = placed[selected] {
                if phase == .ended { commit() }
                else { e.orientation = simd_quatf(angle: -Float(delta), axis: [0, 1, 0]) * e.orientation }
            } else if phase != .ended {
                camera.twist(by: delta)
            }
            if phase == .ended { twistingObject = false }
        }
        h.tap = { location in
            let hit = hitPlacement(at: location, prefer: selected)
            let hitRoom = hit == nil ? hitRoomObject(at: location) : nil
            if hit == nil && hitRoom == nil {
                selected = nil; selectedRoomObject = nil   // only a tap on nothing deselects
            } else if selected == nil && selectedRoomObject == nil {
                if let hit { selected = hit; lockMenuFor = hit } else { selectedRoomObject = hitRoom }
            } else if let hit, hit == selected {
                lockMenuFor = hit
            }   // else: another object while one is selected; switching takes a long press
        }
        h.longPress = { location in
            if let id = hitPlacement(at: location, prefer: selected) {
                if selected != id { selected = id }
            } else if let i = hitRoomObject(at: location) {
                selected = nil; selectedRoomObject = i
            } else { return }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
        return h
    }

    /// What a one-finger drag starting at `point` moves. With a placement selected, only that one: a drag that starts
    /// on or near any object moves it, so a neighbor under the finger can't take over. Scanned furniture selected:
    /// nothing (they can't be dragged, and a drag never switches the selection). Nothing selected: the placement
    /// under the finger. A drag on empty space orbits.
    private func dragTarget(at point: CGPoint) -> UUID? {
        if let selected {
            guard !isLocked(selected),
                  hitPlacement(at: point, prefer: selected) != nil || hitRoomObject(at: point) != nil else { return nil }
            return selected
        }
        guard selectedRoomObject == nil, let id = hitPlacement(at: point), !isLocked(id) else { return nil }
        return id
    }

    private func floorPoint(at point: CGPoint) -> SIMD3<Float>? {
        guard let (o, d) = content?.ray(through: point, in: .local, to: .scene), d.y < -0.01 else { return nil }
        let p = o + d * (-o.y / d.y)
        return [p.x, 0, p.z]
    }

    /// Nearest placed object whose (padded) bounding box the ray passes through. `prefer` (the selection) wins
    /// whenever the ray hits it, even behind another object, and gets a wider margin.
    private func hitPlacement(at point: CGPoint, prefer: UUID? = nil) -> UUID? {
        guard let (o, d) = content?.ray(through: point, in: .local, to: .scene) else { return nil }
        var best: (id: UUID, t: Float)?
        for (id, e) in placed {
            let b = e.visualBounds(relativeTo: e)
            let pad: Float = id == prefer ? 0.25 : 0.12   // fat-finger padding
            let lo = b.min - pad / e.scale, hi = b.max + pad / e.scale
            let ro = e.convert(position: o, from: nil), rd = e.convert(direction: d, from: nil)
            var tmin: Float = 0, tmax = Float.greatestFiniteMagnitude
            for i in 0..<3 {
                var t0 = (lo[i] - ro[i]) / rd[i], t1 = (hi[i] - ro[i]) / rd[i]
                if t0 > t1 { swap(&t0, &t1) }
                tmin = max(tmin, t0); tmax = min(tmax, t1)
            }
            if tmin <= tmax, id == prefer { return id }
            if tmin <= tmax, tmin < best?.t ?? .greatestFiniteMagnitude { best = (id, tmin) }
        }
        return best?.id
    }

    private func roomObjectEntity(_ i: Int) -> Entity? {
        roomEntity?.findEntity(named: RoomBuilder.furniturePrefix + "\(i)")
    }

    /// Scanned (RoomPlan) furniture under the finger, tested against each object's box.
    private func hitRoomObject(at point: CGPoint) -> Int? {
        guard let project, let room = store.room(for: project),
              let (o, d) = content?.ray(through: point, in: .local, to: .scene) else { return nil }
        var best: (i: Int, t: Float)?
        for (i, b) in room.objects.enumerated() {
            guard let e = roomObjectEntity(i), e.isEnabled else { continue }
            let hi = b.dimensions / 2 + 0.05, lo = -hi
            let ro = e.convert(position: o, from: nil), rd = e.convert(direction: d, from: nil)
            var tmin: Float = 0, tmax = Float.greatestFiniteMagnitude
            for k in 0..<3 {
                var t0 = (lo[k] - ro[k]) / rd[k], t1 = (hi[k] - ro[k]) / rd[k]
                if t0 > t1 { swap(&t0, &t1) }
                tmin = max(tmin, t0); tmax = min(tmax, t1)
            }
            if tmin <= tmax, tmin < best?.t ?? .greatestFiniteMagnitude { best = (i, tmin) }
        }
        return best?.i
    }

    // MARK: Fullscreen chrome (Paper E / E2 / E3)

    /// Orbit, pan and zoom only: the card previews the room, it doesn't edit it.
    private var cardHandlers: TouchSurface.Handlers {
        var h = TouchSurface.Handlers()
        h.touchDown = { touched = true; camera.grab() }
        h.touchUp = { camera.release() }
        h.oneFinger = { phase, _, delta, velocity in
            switch phase {
            case .began: break
            case .changed: camera.orbit(by: delta)
            case .ended: camera.endOrbit(velocity: velocity)
            }
        }
        h.twoFingerPan = { delta in camera.pan(by: delta, viewHeight: viewSize.height) }
        h.pinch = { phase, scale in
            switch phase {
            case .began: camera.beginZoom()
            case .changed: camera.zoom(scale: scale)
            case .ended: break
            }
        }
        return h
    }

    private func topChrome(_ project: Project) -> some View {
        HStack(spacing: 8) {
            Button { dismiss() } label: {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(chrome.ink)
                    .frame(width: 44, height: 44).background(chrome.fill, in: Circle())
            }
            .accessibilityLabel("Close fullscreen")
            Text(project.name).font(.forma(12, bold: true)).foregroundStyle(chrome.ink).lineLimit(1)
                .padding(.horizontal, 14).frame(height: 32).background(chrome.fill, in: Capsule())
            Spacer(minLength: 0)
            Button { showObjects.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "list.bullet")
                    Text("Objects").font(.forma(13, bold: true))
                    Text("\(objectRows(project).count)").font(.forma(11, bold: true)).foregroundStyle(Theme.onSage)
                        .padding(.horizontal, 6).frame(minWidth: 22, minHeight: 22).background(Theme.sage, in: Capsule())
                }
                .foregroundStyle(chrome.ink)
                .padding(.horizontal, 14).frame(height: 44).background(chrome.fill, in: Capsule())
            }
            .accessibilityLabel("Objects")
        }
    }

    private enum ObjectRow: Identifiable, Hashable {
        case placement(UUID), room(Int)
        var id: String { switch self { case .placement(let u): u.uuidString; case .room(let i): "room-\(i)" } }
    }

    private func objectRows(_ project: Project) -> [ObjectRow] {
        let room = store.room(for: project)
        let removed = Set(project.removedRoomObjects ?? [])
        let scanned = (room?.objects.indices).map { Array($0).filter { !removed.contains($0) } } ?? []
        return project.placements.map { .placement($0.id) } + scanned.map { .room($0) }
    }

    private func rowInfo(_ row: ObjectRow, project: Project) -> (name: String, dims: String, symbol: String, hidden: Bool, selected: Bool) {
        // No spaces around ×: 3-digit sizes fit the panel row.
        func cm(_ v: SIMD3<Float>) -> String { String(format: "%.0f×%.0f×%.0f cm", v.x * 100, v.z * 100, v.y * 100) }
        switch row {
        case .placement(let id):
            guard let p = project.placements.first(where: { $0.id == id }) else { return ("Item", "", "cube", false, false) }
            let item = CatalogItem.item(p.catalogItem)
            let object = store.objects.first { $0.id == p.objectID }
            let base = naturalSize[id] ?? item?.size ?? object?.boundingBox ?? .zero   // same source as the Size sheet
            return (item?.name ?? object?.name ?? "Item", cm(base * (p.scale ?? .one)), item?.symbol ?? "chair.lounge",
                    hiddenPlacements.contains(id), selected == id)
        case .room(let i):
            let box = store.room(for: project)?.objects[i]
            let label = box?.label == RoomModel.markedLabel ? "Marked item" : (box?.label.capitalized ?? "Item")
            return (label, box.map { cm($0.dimensions) } ?? "", "cube.transparent",
                    project.hiddenRoomObjects?.contains(i) ?? false, selectedRoomObject == i)
        }
    }

    private func objectsPanel(_ project: Project) -> some View {
        let rows = objectRows(project)
        return VStack(alignment: .leading, spacing: 12) {
            // Drag the grabber to resize: it snaps to the nearest of peek, medium and large.
            Capsule().fill(Theme.hairline).frame(width: 36, height: 5)
                .frame(maxWidth: .infinity).padding(.top, 10).padding(.bottom, 4)
                .contentShape(Rectangle())
                .gesture(resizeGesture)
                .accessibilityLabel("Resize objects")
            HStack {
                Text("Objects").font(.forma(18, bold: true))
                Text("\(rows.count)").font(.forma(13)).foregroundStyle(Theme.muted)
                Spacer()
                Button { showObjects = false } label: {
                    Image(systemName: "xmark").font(.system(size: 14, weight: .semibold))
                        .frame(width: 40, height: 40).background(Theme.hairline, in: Circle())
                }
                .accessibilityLabel("Close objects")
            }
            .foregroundStyle(Theme.ink)
            ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(rows) { row in
                        let info = rowInfo(row, project: project)
                        VStack(spacing: 8) {
                            HStack(spacing: 12) {
                                Image(systemName: info.symbol).font(.system(size: 16)).foregroundStyle(Theme.wood)
                                    .frame(width: 36, height: 36).background(Theme.tiles[0], in: RoundedRectangle(cornerRadius: 10))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(info.name).font(.forma(13, bold: true)).foregroundStyle(Theme.ink).lineLimit(1)
                                    Text(info.dims).font(.forma(11)).foregroundStyle(Theme.muted).lineLimit(1).minimumScaleFactor(0.9)
                                }
                                Spacer(minLength: 4)
                                Button { toggleVisibility(row) } label: {
                                    Image(systemName: info.hidden ? "eye.slash" : "eye").foregroundStyle(Theme.ink)
                                        .frame(width: 36, height: 36)
                                }
                                .accessibilityLabel(info.hidden ? "Show \(info.name)" : "Hide \(info.name)")
                            }
                            if info.selected { rowActions(row, project: project) }
                        }
                        .padding(10)
                        .background(info.selected ? Theme.tiles[0] : .clear, in: RoundedRectangle(cornerRadius: 18))
                        .contentShape(Rectangle())
                        .onTapGesture { select(row) }
                        .overlay(alignment: .top) { if !info.selected { Theme.hairline.frame(height: 1) } }
                        .id(row)
                    }
                }
            }
            .scrollIndicators(.hidden)
            // An object tapped in the room may sit far down the list: bring its row (and actions) into view.
            .task(id: selectedRow) { if let selectedRow { withAnimation { proxy.scrollTo(selectedRow, anchor: .center) } } }
            }
            undoBar.frame(maxWidth: .infinity)
            Button { showAddChoice = true } label: { Label("Add object", systemImage: "plus") }
                .buttonStyle(PillButtonStyle())
        }
        .padding(.horizontal, 16).padding(.bottom, 16)
        .frame(maxWidth: .infinity)
        .frame(height: objectsHeight(drag: objectsDrag), alignment: .top)
        .background {
            UnevenRoundedRectangle(topLeadingRadius: 28, topTrailingRadius: 28, style: .continuous)
                .fill(Theme.ground).ignoresSafeArea(edges: .bottom)
        }
        .shadow(color: .black.opacity(0.08), radius: 20)
    }

    private enum ObjectsDetent: CaseIterable {
        case peek, medium, large
        func height(in total: CGFloat) -> CGFloat {
            switch self {
            case .peek: 180
            case .medium: 440
            case .large: max(440, total - 120)
            }
        }
    }

    private func objectsHeight(drag: CGFloat = 0) -> CGFloat {
        let large = ObjectsDetent.large.height(in: viewSize.height)
        return min(max(objectsDetent.height(in: viewSize.height) - drag, ObjectsDetent.peek.height(in: viewSize.height) - 60), large)
    }

    private var resizeGesture: some Gesture {
        DragGesture()
            .updating($objectsDrag) { v, state, _ in state = v.translation.height }
            .onEnded { v in
                let end = objectsHeight(drag: v.predictedEndTranslation.height)
                objectsDetent = ObjectsDetent.allCases.min {
                    abs($0.height(in: viewSize.height) - end) < abs($1.height(in: viewSize.height) - end)
                } ?? .medium
            }
    }

    private var selectedRow: ObjectRow? { selected.map { .placement($0) } ?? selectedRoomObject.map { .room($0) } }

    private func select(_ row: ObjectRow) {
        switch row {
        case .placement(let id): selected = id
        case .room(let i): selectedRoomObject = i
        }
    }

    private func toggleVisibility(_ row: ObjectRow) {
        switch row {
        case .placement(let id):
            if hiddenPlacements.remove(id) == nil { hiddenPlacements.insert(id) }
            placed[id]?.isEnabled = !hiddenPlacements.contains(id)
        case .room(let i):
            guard var project else { return }
            var hidden = Set(project.hiddenRoomObjects ?? [])
            if hidden.remove(i) == nil { hidden.insert(i) }
            project.hiddenRoomObjects = hidden.isEmpty ? nil : hidden.sorted()
            store.update(project)
            roomObjectEntity(i)?.isEnabled = !hidden.contains(i)
        }
    }

    private func rotate(_ id: UUID) {
        guard let e = placed[id] else { return }
        e.orientation = simd_quatf(angle: .pi / 8, axis: [0, 1, 0]) * e.orientation
        commit()
    }

    // MARK: Hint and selected-row actions

    /// "Removed Sofa · Undo": restores the project snapshot taken before the Delete or Replace.
    @ViewBuilder private var undoBar: some View {
        if let undo {
            HStack(spacing: 16) {
                Text(undo.title).font(.forma(13)).lineLimit(1)
                Button { restore(undo.snapshot) } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward").font(.forma(13, bold: true)).foregroundStyle(Theme.sage)
                }
            }
            .foregroundStyle(Theme.onSage)
            .padding(.horizontal, 18).frame(height: 44)
            .background(Theme.ink, in: Capsule())
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    @ViewBuilder private var hint: some View {
        if showObjects { EmptyView() }   // the panel covers the hint's spot
        else if objectHint { HintPill("Drag to move · Twist to rotate", fill: chrome.fill, ink: chrome.ink) }
        else if showHint { HintPill("Drag to orbit · Pinch to zoom", fill: chrome.fill, ink: chrome.ink) }
    }

    /// Actions for the selected row in the Objects panel. Move = drag, rotate = twist or the Rotate button.
    @ViewBuilder private func rowActions(_ row: ObjectRow, project: Project) -> some View {
        switch row {
        case .placement(let id):
            if let product = project.placements.first(where: { $0.id == id })?.product {
                Link(destination: product.productURL) {
                    HStack(spacing: 6) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(product.title).font(.forma(12, bold: true)).lineLimit(1)
                            Text("\(product.price) · \(product.retailer)").font(.forma(11)).foregroundStyle(Theme.ink.opacity(0.6))
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.right.square")
                    }
                    .foregroundStyle(Theme.ink)
                }
                .accessibilityLabel("Open product \(product.title)")
                if product.imageURL != nil, project.placements.first(where: { $0.id == id })?.catalogItem != nil {
                    let busy = making3D?.id == id
                    PanelAction(busy ? "Making 3D…" : failed3D.contains(id) ? "3D failed, try again" : "Make it 3D (beta)",
                                icon: busy ? "hourglass" : "cube.transparent") { makeIt3D(id) }
                        .disabled(making3D != nil)
                }
            }
            let locked = isLocked(id)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                PanelAction("Rotate", icon: "arrow.clockwise") { rotate(id) }.disabled(locked)   // locked = stays put, like drag/twist
                PanelAction("Size", icon: "slider.horizontal.3") { editing = id }
                PanelAction(locked ? "Unlock" : "Lock", icon: locked ? "lock.fill" : "lock.open") { toggleLock(id) }
                PanelAction("Remove", icon: "trash") { remove(id) }
                if Capabilities.canScanObject { PanelAction("Scan real", icon: "camera.viewfinder") { scanTarget = .placement(id) } }
            }
        case .room(let i):
            if let room = store.room(for: project), room.objects.indices.contains(i) {
                let box = room.objects[i]
                let marked = box.label == RoomModel.markedLabel
                // Vision suggestion for marked items (SceneClassifier), offered first.
                let suggestion = CatalogItem.item(box.attributes?.first { $0.hasPrefix("Suggest.") }.map { String($0.dropFirst(8)) })
                if let suggestion {
                    PanelAction("Use \(suggestion.name)", icon: suggestion.symbol, filled: true) {
                        Task { await replaceRoomObject(i, catalog: suggestion) }
                    }
                }
                HStack(spacing: 8) {
                    Menu {
                        if !store.objects.isEmpty {
                            Section("Your scans") {
                                ForEach(store.objects) { o in Button(o.name) { Task { await replaceRoomObject(i, object: o) } } }
                            }
                        }
                        Section("Catalog") {
                            ForEach(CatalogItem.all) { c in
                                Button(c.name, systemImage: c.symbol) { Task { await replaceRoomObject(i, catalog: c) } }
                            }
                        }
                    } label: { PanelLabel(title: "Replace", icon: "arrow.triangle.2.circlepath") }
                        .accessibilityLabel("Replace")
                    if !marked { PanelAction("Size", icon: "slider.horizontal.3") { Task { await editRoomObject(i, room: room) } } }
                }
                if Capabilities.canScanObject { PanelAction("Scan real", icon: "camera.viewfinder") { scanTarget = .roomObject(i) } }
            }
        }
    }

    /// Add object, step 1: a real scan (guided by Object Capture, then dropped in) or a preset (the catalog).
    private var addChoiceSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add an object").font(.forma(18, bold: true)).foregroundStyle(Theme.ink)
            addChoice("Scan a physical object", icon: "camera.viewfinder", enabled: Capabilities.canScanObject) {
                showAddChoice = false
                Task { try? await Task.sleep(for: .milliseconds(350)); scanTarget = .new }   // after the sheet is gone
            }
            addChoice("Select a preset", icon: "square.grid.2x2") {
                showAddChoice = false
                Task { try? await Task.sleep(for: .milliseconds(350)); showCatalog = true }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.ground)
        .presentationDetents([.height(250)])
        .presentationBackground(Theme.ground)
    }

    private func addChoice(_ title: String, icon: String, enabled: Bool = true,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.system(size: 22, weight: .semibold)).foregroundStyle(Theme.wood)
                    .frame(width: 52, height: 52).background(Theme.hairline, in: RoundedRectangle(cornerRadius: 16))
                Text(title).font(.forma(14, bold: true)).foregroundStyle(Theme.ink)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.wood)
            }
            .padding(14)
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.ink.opacity(0.15)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled).opacity(enabled ? 1 : 0.45)
        .accessibilityLabel(title)
    }

    private var catalogSheet: some View {
        NavigationStack {
            ScrollView {
                if !store.objects.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Your scans").font(.forma(13, bold: true)).foregroundStyle(Theme.ink)
                        ForEach(store.objects) { object in
                            Button {
                                showCatalog = false
                                Task { await add(object) }
                            } label: {
                                Label(object.name, systemImage: "plus.circle.fill").font(.forma(13)).foregroundStyle(Theme.ink)
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).frame(height: 44)
                                    .overlay(Capsule().strokeBorder(Theme.ink, lineWidth: 1))
                            }
                        }
                    }
                    .padding([.horizontal, .top])
                    Text("Catalog").font(.forma(13, bold: true)).foregroundStyle(Theme.ink)
                        .frame(maxWidth: .infinity, alignment: .leading).padding([.horizontal, .top])
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 12)], spacing: 12) {
                    ForEach(CatalogItem.all) { item in
                        Button {
                            showCatalog = false
                            Task { await add(catalog: item) }
                        } label: {
                            VStack(spacing: 8) {
                                Image(systemName: item.symbol).font(.title2).frame(height: 30).foregroundStyle(Theme.wood)
                                Text(item.name).font(.forma(12, bold: true)).foregroundStyle(Theme.ink).lineLimit(1)
                                Text(String(format: "%.1f × %.1f m", item.size.x, item.size.z))
                                    .font(.forma(10)).foregroundStyle(Theme.muted)
                            }
                            .frame(maxWidth: .infinity).padding(.vertical, 14)
                            .background(Theme.hairline, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
            }
            .background(Theme.ground)
            .navigationTitle("Add object")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showCatalog = false } } }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: Actions

    /// Saves the room's default view as its Home thumbnail, unless the user has already moved the camera.
    /// The snapshot's empty (transparent) background is trimmed and the room is fitted onto a square in the app's ground color.
    private func saveThumbnail() {
        guard !touched, !lowWalls, let shot = captureDesignerSnapshot(opaque: false, size: viewSize, fallbackToWindow: false)?.cgImage, let box = Self.contentBounds(shot),
              let room = shot.cropping(to: box) else { return }
        let side: CGFloat = 360, pad: CGFloat = 18
        let scale = min((side - 2 * pad) / box.width, (side - 2 * pad) / box.height)
        let size = CGSize(width: box.width * scale, height: box.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let out = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).jpegData(withCompressionQuality: 0.8) { ctx in
            UIColor(Theme.ground).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
            UIImage(cgImage: room).draw(in: CGRect(origin: CGPoint(x: (side - size.width) / 2, y: (side - size.height) / 2), size: size))
        }
        try? out.write(to: RoomThumb.url(projectID), options: .atomic)
        store.filesChanged()
    }

    /// Bounding box of visible pixels (the rendered room), found on a 128-px-wide copy. nil if empty.
    private static func contentBounds(_ image: CGImage) -> CGRect? {
        let w = 128, h = max(1, image.height * 128 / max(image.width, 1))
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var lo = (x: w, y: h), hi = (x: -1, y: -1)
        for y in 0..<h { for x in 0..<w {
            let i = (y * w + x) * 4
            guard px[i + 3] > 8 else { continue }   // alpha
            lo = (min(lo.x, x), min(lo.y, y)); hi = (max(hi.x, x), max(hi.y, y))
        } }
        guard hi.x >= lo.x else { return nil }
        let k = CGFloat(image.width) / CGFloat(w)   // rows in the bitmap run top-down, like CGImage cropping
        return CGRect(x: CGFloat(lo.x) * k, y: CGFloat(lo.y) * k, width: CGFloat(hi.x - lo.x + 1) * k, height: CGFloat(hi.y - lo.y + 1) * k)
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }

    private func rebuildRoom(_ room: RoomModel) {
        roomEntity?.removeFromParent()
        let built = RoomBuilder.build(room, wallScale: lowWalls ? 0.3 : 1)
        scene.addChild(built.entity)
        roomEntity = built.entity
        roomSize = built.size
        outline = room.floorOutline
        let offset = built.entity.children.first?.position ?? .zero   // RoomBuilder's content offset (-center)
        walls.collect(from: built.entity, outline: room.floorOutline?.map { SIMD2($0.x + offset.x, $0.z + offset.z) })
        for i in (project?.hiddenRoomObjects ?? []) + (project?.removedRoomObjects ?? []) { roomObjectEntity(i)?.isEnabled = false }
        let wall = Finish.wall(project?.wallFinish), floor = Finish.floor(project?.floorFinish)
        Task {
            await Finish.apply(to: built.entity, wall: wall, floor: floor)
            await RoomBuilder.furnish(built, room: room)
            try? await Task.sleep(for: .seconds(1.5))   // placements stream in, cutaway walls finish fading
            saveThumbnail()
        }
    }

    private func spawn(_ p: Placement) async {
        let e: Entity
        if let item = CatalogItem.item(p.catalogItem) {
            e = await item.entity()
        } else if let object = store.objects.first(where: { $0.id == p.objectID }) {
            e = await RoomBuilder.placedEntity(for: object, url: store.modelURL(for: object))
            print("RoomVibe: spawned \(object.name) file=\(object.modelFile ?? "procedural") extents=\(e.visualBounds(relativeTo: e).extents)")
        } else {
            print("RoomVibe: placement \(p.id) references missing object \(p.objectID)")
            return
        }
        // Removed (or undone away) while its model loaded: don't leave a ghost entity behind.
        guard project?.placements.contains(where: { $0.id == p.id }) == true else { return }
        naturalSize[p.id] = e.visualBounds(relativeTo: e).extents
        placed[p.id]?.removeFromParent()   // never two entities for one placement
        e.name = p.id.uuidString
        e.position = p.position
        e.orientation = simd_quatf(angle: p.yRotation, axis: [0, 1, 0])
        e.scale = p.scale ?? .one
        scene.addChild(e)
        placed[p.id] = e
    }

    private func isLocked(_ id: UUID) -> Bool {
        project?.placements.first { $0.id == id }?.locked ?? false
    }

    private func toggleLock(_ id: UUID) {
        guard var project, let i = project.placements.firstIndex(where: { $0.id == id }) else { return }
        project.placements[i].locked = !(project.placements[i].locked ?? false)
        store.update(project)
        lifts += 1
    }

    /// Tiny quick menu, shown only after a tap on a placed object and hidden by any other touch. Bottom-left keeps
    /// it clear of the room and of the Objects panel, which opens at the bottom whenever something is selected.
    @ViewBuilder private func lockMenu() -> some View {
        if let id = lockMenuFor, id == selected, project?.placements.contains(where: { $0.id == id }) == true {
            let locked = isLocked(id)
            Button { toggleLock(id) } label: {
                HStack(spacing: 8) {
                    Image(systemName: locked ? "lock.fill" : "lock.open").font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.sageDeep)
                    Text(locked ? "Locked" : "Lock").font(.forma(12, bold: true)).foregroundStyle(Theme.ink)
                }
                .padding(.horizontal, 14).frame(height: 36)
                .background(Theme.sand, in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.sage, lineWidth: 1.5))
            }
            .accessibilityLabel(locked ? "Unlock in place" : "Lock in place")
            .transition(.opacity.combined(with: .scale(scale: 0.96)))
        }
    }

    /// Products added from Vibe shopping (VibeView writes them to the store while this view stays open underneath).
    private func spawnShoppedProducts() {
        Task {
            var clamped: [UUID: SIMD3<Float>] = [:]
            for p in project?.placements ?? [] where p.product != nil && placed[p.id] == nil {
                await spawn(p)
                guard let e = placed[p.id] else { continue }
                if p.position == .zero { e.position = freeSpot(for: e) }   // fresh from Vibe: don't stack on the center
                e.position = clamp(e.position, keeping: e)
                clamped[p.id] = e.position
            }
            // Save just these positions; commit() would also drop a pending Undo.
            guard !clamped.isEmpty, var project else { return }
            for i in project.placements.indices {
                if let pos = clamped[project.placements[i].id] { project.placements[i].position = pos }
            }
            store.update(project)
        }
    }

    /// The free floor spot nearest the room's center for `entity`, clear of other placements and of the visible scanned
    /// furniture. Flat items (rugs) don't count as taken: furniture can stand on them.
    private func freeSpot(for entity: Entity) -> SIMD3<Float> {
        guard let model = entity.children.first else { return entity.position }
        let size = model.visualBounds(relativeTo: scene).extents
        var taken: [(lo: SIMD2<Float>, hi: SIMD2<Float>)] = []
        func take(_ e: Entity) {
            let b = e.visualBounds(relativeTo: scene)
            if b.extents.y > 0.05 { taken.append((SIMD2(b.min.x, b.min.z), SIMD2(b.max.x, b.max.z))) }
        }
        for (_, other) in placed where other !== entity { if let m = other.children.first { take(m) } }   // not the selection disc
        func furniture(in e: Entity) {
            for c in e.children {
                if c.name.hasPrefix(RoomBuilder.furniturePrefix) { if c.isEnabled { take(c) } } else { furniture(in: c) }
            }
        }
        if let roomEntity { furniture(in: roomEntity) }
        let poly = outline.flatMap { o in roomEntity?.children.first.map { r in o.map { SIMD2($0.x + r.position.x, $0.z + r.position.z) } } }
        let xz = FloorClamp.freeSpot(near: .zero, half: SIMD2(size.x, size.z) / 2, taken: taken,
                                     bounds: roomSize / 2 - RoomBuilder.wallThickness / 2, outline: poly)
        return [xz.x, entity.position.y, xz.y]
    }

    /// SAM 3D (/vibe/model3d) turns the product photo into a model that replaces its catalog stand-in, fitted to the
    /// stand-in's current size (SAM 3D output has no real-world scale).
    private func makeIt3D(_ id: UUID) {
        guard making3D == nil, let p = project?.placements.first(where: { $0.id == id }), let product = p.product,
              let image = product.imageURL else { return }
        failed3D.remove(id)
        let task = Task {
            do {
                let job = try await APIClient.shared.startModel3D(imageURL: image, category: product.category ?? p.catalogItem ?? "")
                let deadline = ContinuousClock.now + .seconds(240)
                while true {
                    try Task.checkCancellation()
                    let status = try await APIClient.shared.pollModel3D(job)
                    if status.status == .done, let usdz = status.usdz { try await install3D(usdz, for: id, name: product.title); break }
                    if status.status == .failed || ContinuousClock.now > deadline { throw APIError.badResponse }
                    try await Task.sleep(for: .seconds(3))
                }
            } catch is CancellationError {
            } catch {
                print("RoomVibe: Make it 3D failed: \(error)")
                failed3D.insert(id)
            }
            making3D = nil
        }
        making3D = (id, task)
    }

    private func install3D(_ usdz: Data, for id: UUID, name: String) async throws {
        guard let stand = placed[id], let p = project?.placements.first(where: { $0.id == id }) else { return }
        let target = (naturalSize[id] ?? stand.visualBounds(relativeTo: stand).extents) * (p.scale ?? .one)
        try Task.checkCancellation()
        let object = try await store.saveModel(usdz: usdz, name: name)
        // Not in the library yet: drop the files if the job was cancelled or the box removed meanwhile.
        guard !Task.isCancelled, project?.placements.contains(where: { $0.id == id }) == true else {
            store.discardModel(object)
            try Task.checkCancellation()
            return
        }
        do { try store.addObject(object) } catch { store.delete(object); throw error }
        let wasSelected = selected
        await applyScan(object, to: .placement(id))
        selected = wasSelected   // applyScan selects the swapped item; keep the user's current selection instead
        // Fit it to the box it replaces (SAM 3D output has no real-world scale); Reset Size returns here.
        guard var project, let k = project.placements.firstIndex(where: { $0.id == id }) else { return }
        let fit = target / object.boundingBox
        project.placements[k].scale = fit
        project.placements[k].fitScale = fit
        store.update(project)
        placed[id]?.scale = fit
    }

    private func baseScale(_ id: UUID) -> SIMD3<Float> {
        project?.placements.first { $0.id == id }?.scale ?? .one
    }

    /// Drops the object where the user is looking (the camera's floor target), then selects it.
    private func add(_ object: ScannedObject) async {
        guard var project else { return }
        adding = object.name
        defer { adding = nil }
        let p = Placement(id: UUID(), objectID: object.id, position: clamp(camera.goal.target), yRotation: 0)
        project.placements.append(p)
        store.update(project)
        await spawn(p)
        if let e = placed[p.id] { e.position = clamp(e.position, keeping: e); commit(); dropIn(e) }
        selected = p.id
        flashObjectHint()
    }

    private func add(catalog item: CatalogItem) async {
        guard var project else { return }
        let p = Placement(id: UUID(), objectID: Placement.catalogObjectID, position: clamp(camera.goal.target),
                          yRotation: 0, catalogItem: item.id)
        project.placements.append(p)
        store.update(project)
        await spawn(p)
        if let e = placed[p.id] { e.position = clamp(e.position, keeping: e); commit(); dropIn(e) }
        selected = p.id
        flashObjectHint()   // guide the next step: move and turn it
    }

    /// "Drag to move · Twist to rotate" for a few seconds, without holding up the caller.
    private func flashObjectHint() {
        objectHint = true
        Task { try? await Task.sleep(for: .seconds(4)); objectHint = false }
    }

    /// New item falls in from a little above and settles, with a light tap. Purely visual: already committed.
    private func dropIn(_ e: Entity) {
        let rest = e.transform
        var start = rest
        start.translation.y += 0.35
        start.scale = rest.scale * 0.9
        e.transform = start
        e.move(to: rest, relativeTo: e.parent, duration: 0.45, timingFunction: .easeOut)
        lifts += 1
    }

    /// Remove a scanned piece of furniture and put a scan or catalog item exactly where it stood, facing the same way.
    /// Catalog replacements are stretched to RoomPlan's measured box; scans keep their real scale.
    /// Wall-mounted objects keep their height (bottom of RoomPlan's box above the floor).
    private func replaceRoomObject(_ i: Int, object: ScannedObject? = nil, catalog: CatalogItem? = nil) async {
        guard var project, let anchor = roomObjectEntity(i), let box = store.room(for: project)?.objects[i] else { return }
        let pos = anchor.position(relativeTo: scene)
        let bottom = pos.y - box.dimensions.y / 2
        var yaw = { let f = anchor.orientation(relativeTo: scene).act([0, 0, 1]); return atan2(f.x, f.z) }()
        if box.label == RoomModel.markedLabel, let away = yawAwayFromNearestWall(pos) { yaw = away }
        var p = Placement(id: UUID(), objectID: object?.id ?? Placement.catalogObjectID,
                          position: [pos.x, bottom > 0.1 ? bottom : 0, pos.z], yRotation: yaw, catalogItem: catalog?.id)
        if let catalog { p.scale = box.dimensions / catalog.size; p.fitScale = p.scale }
        project.placements.append(p)
        project.removedRoomObjects = Array(Set((project.removedRoomObjects ?? []) + [i])).sorted()
        store.update(project)
        anchor.isEnabled = false
        selectedRoomObject = nil
        await spawn(p)
        selected = p.id
    }

    /// Edit = turn scanned furniture into an editable placement (same model, same box), then open the editor.
    private func editRoomObject(_ i: Int, room: RoomModel) async {
        var key = RoomBuilder.furnitureModel(for: room.objects[i])
        if key == "sink", let e = roomObjectEntity(i), e.position(relativeTo: scene).y - room.objects[i].dimensions.y / 2 > 0.2 {
            key = "sink_wall"   // floating sink = wall-mounted basin
        }
        let item = CatalogItem.all.first { $0.model == key } ?? CatalogItem.item("custom_box")!
        await replaceRoomObject(i, catalog: item)
        editing = selected   // replaceRoomObject selects the new placement
    }

    /// Facing for things marked on a wall: front points into the room, away from the closest wall.
    private func yawAwayFromNearestWall(_ p: SIMD3<Float>) -> Float? {
        guard let project, let room = store.room(for: project), let roomEntity else { return nil }
        let center = roomEntity.children.first?.position ?? .zero   // RoomBuilder's content offset
        let local = p - center
        var best: (d: Float, n: SIMD3<Float>)?
        for w in room.walls {
            let c = SIMD3(w.columns[3].x, w.columns[3].y, w.columns[3].z), n = SIMD3(w.columns[2].x, 0, w.columns[2].z)
            let x = SIMD3(w.columns[0].x, 0, w.columns[0].z)
            guard abs(simd_dot(local - c, x)) < w.dimensions.x / 2 + 0.2 else { continue }
            let d = simd_dot(local - c, n)
            if abs(d) < best?.d ?? .greatestFiniteMagnitude { best = (abs(d), d >= 0 ? n : -n) }
        }
        guard let n = best?.n, best!.d < 0.8 else { return nil }
        return atan2(n.x, n.z)
    }

    /// A fresh scan replaces a placement (keeping spot, facing and height) or a piece of scanned furniture.
    private func applyScan(_ object: ScannedObject, to target: ScanTarget) async {
        switch target {
        case .new:
            await add(object)   // drops in where the user is looking, selected, with the move/turn hint
        case .roomObject(let i):
            await replaceRoomObject(i, object: object)
        case .placement(let id):
            guard var project, let k = project.placements.firstIndex(where: { $0.id == id }) else { return }
            project.placements[k].objectID = object.id
            project.placements[k].catalogItem = nil
            project.placements[k].scale = nil
            project.placements[k].fitScale = nil
            store.update(project)
            placed.removeValue(forKey: id)?.removeFromParent()
            await spawn(project.placements[k])
            selected = id
        }
    }

    // MARK: Editor

    /// Size (per axis) and mounting height of one placement, applied live. Centimeters, like the Objects panel.
    private func editor(_ id: UUID) -> some View {
        NavigationStack {
            Form {
                Section {
                    dimensionRow("Width", id: id, axis: 0)
                    dimensionRow("Depth", id: id, axis: 2)
                    dimensionRow("Height", id: id, axis: 1)
                    Button("Reset Size") { setScale(id) { _ in fitScale(id) } }
                        .font(.forma(14, bold: true)).foregroundStyle(Theme.sageDeep)
                } header: { editorHeader("Size") }
                Section {
                    LabeledContent {
                        Text(Self.cm(elevation(id))).font(.forma(14, bold: true)).foregroundStyle(Theme.ink)
                    } label: { Text("Above floor") }
                    Slider(value: Binding(get: { Double(elevation(id)) }, set: { setElevation(id, Float($0)) }), in: 0...2.4, step: 0.01)
                        .accessibilityLabel("Height above floor")
                    Button("Put on Floor") { setElevation(id, 0) }
                        .font(.forma(14, bold: true)).foregroundStyle(Theme.sageDeep)
                        .disabled(elevation(id) == 0)
                } header: { editorHeader("Mounting") } footer: {
                    Text("Raise wall-mounted items like sinks, shelves, TVs or lamps.").font(.forma(11)).foregroundStyle(Theme.muted)
                }
            }
            .font(.forma(14)).foregroundStyle(Theme.ink).tint(Theme.sage)
            .scrollContentBackground(.hidden).background(Theme.ground)
            .navigationTitle(name(of: id) ?? "Size")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(name(of: id) ?? "Size").font(.forma(15, bold: true)).foregroundStyle(Theme.ink).lineLimit(1)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { editing = nil }.font(.forma(14, bold: true)).foregroundStyle(Theme.ink)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Theme.ground)
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
    }

    private func editorHeader(_ title: String) -> some View {
        Text(title).font(.forma(11, bold: true)).foregroundStyle(Theme.muted).textCase(nil)
    }

    private static func cm(_ meters: Float) -> String { String(format: "%.0f cm", meters * 100) }

    private func dimensionRow(_ title: String, id: UUID, axis: Int) -> some View {
        let natural = naturalSize[id] ?? .one
        let size = natural * baseScale(id)
        return Stepper(value: Binding(
            get: { Double(size[axis]) },
            set: { v in setScale(id) { s in var s = s; s[axis] = max(Float(v), 0.05) / max(natural[axis], 0.001); return s } }
        ), in: 0.05...6, step: 0.05) {
            LabeledContent {
                Text(Self.cm(size[axis])).font(.forma(14, bold: true)).foregroundStyle(Theme.ink).monospacedDigit()
            } label: { Text(title) }
        }
    }

    private func setScale(_ id: UUID, _ change: (SIMD3<Float>) -> SIMD3<Float>) {
        guard var project, let k = project.placements.firstIndex(where: { $0.id == id }) else { return }
        let s = change(project.placements[k].scale ?? .one)
        guard s != (project.placements[k].scale ?? .one) else { return }
        undo = nil
        project.placements[k].scale = s == .one ? nil : s
        store.update(project)
        placed[id]?.scale = s
        if let e = placed[id] { highlight(e) }   // resize the selection disc
    }

    private func fitScale(_ id: UUID) -> SIMD3<Float> { project?.placements.first { $0.id == id }?.fitScale ?? .one }

    private func elevation(_ id: UUID) -> Float { project?.placements.first { $0.id == id }?.position.y ?? 0 }

    private func setElevation(_ id: UUID, _ y: Float) {
        guard var project, let k = project.placements.firstIndex(where: { $0.id == id }) else { return }
        undo = nil   // restore() wouldn't move the live entity back down
        project.placements[k].position.y = y
        store.update(project)
        placed[id]?.position.y = y
    }

    private func hideRoomObject(_ i: Int) {
        guard var project else { return }
        offerUndo("Hidden", project)
        project.hiddenRoomObjects = Array(Set((project.hiddenRoomObjects ?? []) + [i])).sorted()
        store.update(project)
        roomObjectEntity(i)?.isEnabled = false
        selectedRoomObject = nil
    }

    private func restoreHidden() {
        guard var project else { return }
        // Saves from before removedRoomObjects put replaced furniture here too. A placement standing on the
        // object's spot means it was replaced: keep it gone instead of showing a duplicate.
        let replaced = (project.hiddenRoomObjects ?? []).filter { i in
            guard let c = roomObjectEntity(i)?.position(relativeTo: scene) else { return false }
            return project.placements.contains { simd_distance(SIMD2($0.position.x, $0.position.z), SIMD2(c.x, c.z)) < 0.15 }
        }
        for i in project.hiddenRoomObjects ?? [] where !replaced.contains(i) { roomObjectEntity(i)?.isEnabled = true }
        if !replaced.isEmpty { project.removedRoomObjects = Array(Set((project.removedRoomObjects ?? []) + replaced)).sorted() }
        project.hiddenRoomObjects = nil
        store.update(project)
    }


    private func remove(_ id: UUID) {
        guard var project else { return }
        offerUndo("Deleted", project)
        if let e = placed.removeValue(forKey: id) {   // shrink away, then go
            var gone = e.transform
            gone.scale *= 0.01
            e.move(to: gone, relativeTo: e.parent, duration: 0.22, timingFunction: .easeIn)
            Task { try? await Task.sleep(for: .milliseconds(240)); e.removeFromParent() }
        }
        project.placements.removeAll { $0.id == id }
        store.update(project)
        selected = nil
    }

    private func offerUndo(_ title: String, _ snapshot: Project) {
        undo = (title, snapshot)
        Task {
            try? await Task.sleep(for: .seconds(5))
            if undo?.snapshot == snapshot { undo = nil }
        }
    }

    /// Put the project back as it was before the last Delete / Hide: placements respawn, room objects re-show.
    private func restore(_ snapshot: Project) {
        undo = nil
        store.update(snapshot)
        let kept = Set(snapshot.placements.map(\.id))
        for (id, e) in placed where !kept.contains(id) {   // e.g. a product added from Vibe after the snapshot
            e.removeFromParent()
            placed[id] = nil
            if selected == id { selected = nil }
        }
        let gone = Set((snapshot.hiddenRoomObjects ?? []) + (snapshot.removedRoomObjects ?? []))
        for i in (store.room(for: snapshot)?.objects.indices ?? 0..<0) { roomObjectEntity(i)?.isEnabled = !gone.contains(i) }
        for p in snapshot.placements where placed[p.id] == nil { Task { await spawn(p) } }
    }

    /// Selection marker: bright corner brackets around the object's box, a solid ring and a tinted disc on the floor.
    /// Parented to the object so it follows drags. Built in meters inside a container that divides out the object's
    /// scale, so bars keep their thickness on stretched or resized items.
    private func highlight(_ e: Entity?) {
        highlighted?.findEntity(named: "selection")?.removeFromParent()
        highlighted = e
        guard let e else { return }
        let s = e.scale
        let b = e.visualBounds(relativeTo: e)
        let lo = b.min * s - 0.03, hi = b.max * s + 0.03, size = hi - lo
        let mark = Entity()
        mark.name = "selection"
        mark.scale = 1 / s
        let accent = UnlitMaterial(color: UIColor(Theme.selection))

        // Corner brackets: three legs from each of the 8 corners, pointing inward.
        let leg = min(0.3, size.min() * 0.4), bar: Float = 0.035
        for corner in 0..<8 {
            let c = SIMD3<Float>(corner & 1 == 0 ? lo.x : hi.x, corner & 2 == 0 ? lo.y : hi.y, corner & 4 == 0 ? lo.z : hi.z)
            for axis in 0..<3 {
                var extent = SIMD3<Float>(repeating: bar)
                extent[axis] = leg
                var inward = SIMD3<Float>.zero
                inward[axis] = (c[axis] == lo[axis] ? 1 : -1) * (leg - bar) / 2
                let piece = ModelEntity(mesh: .generateBox(size: extent), materials: [accent])
                piece.position = c + inward
                mark.addChild(piece)
            }
        }

        // On the floor: a solid ring and a translucent disc under the footprint.
        let floorY = 0.004 - e.position(relativeTo: scene).y
        let center = SIMD3<Float>((lo.x + hi.x) / 2, floorY, (lo.z + hi.z) / 2)
        let radius = max(size.x, size.z) / 2 + 0.06
        let segments = 48
        for k in 0..<segments {
            let a = Float(k) / Float(segments) * 2 * .pi
            let seg = ModelEntity(mesh: .generateBox(size: [2 * .pi * radius / Float(segments) * 1.15, 0.008, 0.05]),
                                  materials: [accent])
            seg.position = center + [radius * cos(a), 0, radius * sin(a)]
            seg.orientation = simd_quatf(angle: -a - .pi / 2, axis: [0, 1, 0])   // along the tangent
            mark.addChild(seg)
        }
        var tint = UnlitMaterial(color: UIColor(Theme.selection))
        tint.blending = .transparent(opacity: 0.25)
        let disc = ModelEntity(mesh: .generateCylinder(height: 0.002, radius: radius), materials: [tint])
        disc.position = center - [0, 0.002, 0]
        mark.addChild(disc)
        e.addChild(mark)

        // Pops in: a touch large, then settles onto the object.
        let rest = mark.transform
        var start = rest
        start.scale = rest.scale * 1.12
        mark.transform = start
        mark.move(to: rest, relativeTo: e, duration: 0.22, timingFunction: .easeOut)
    }

    /// Write entity transforms back to the project. `rotation` overrides an in-flight animation.
    private func commit(rotation: (Entity, simd_quatf)? = nil) {
        guard var project else { return }
        undo = nil
        for i in project.placements.indices {
            guard let e = placed[project.placements[i].id] else { continue }
            let q = rotation?.0 === e ? rotation!.1 : e.orientation
            project.placements[i].position = e.position
            project.placements[i].yRotation = q.angle * (q.axis.y < 0 ? -1 : 1)
        }
        store.update(project)
    }

    /// Keeps `entity`'s footprint (not just its center) inside the walls: the bounding rectangle per axis,
    /// then the scanned floor outline (L-shaped rooms).
    private func clamp(_ p: SIMD3<Float>, keeping entity: Entity? = nil) -> SIMD3<Float> {
        var half = SIMD2<Float>.zero
        // The model is the first child (the selection disc would inflate the bounds).
        if let model = entity?.children.first {
            let b = model.visualBounds(relativeTo: entity?.parent)
            half = SIMD2(b.extents.x, b.extents.z) / 2
        }
        let h = simd_max(roomSize / 2 - half - RoomBuilder.wallThickness / 2, .zero)
        var xz = SIMD2(min(max(p.x, -h.x), h.x), min(max(p.z, -h.y), h.y))
        if let outline, let offset = roomEntity?.children.first?.position {
            let poly = outline.map { SIMD2($0.x + offset.x, $0.z + offset.z) }
            xz = FloorClamp.clamp(footprint: xz, half: half, to: poly, wall: RoomBuilder.wallThickness / 2)
        }
        return [xz.x, max(p.y, 0), xz.y]   // y = mounting height
    }
}

/// Dollhouse cutaway: walls (and their doors/windows) between the camera and the room fade out, so the
/// interior is always visible from any orbit angle. Plain class: runs every frame.
@MainActor
final class WallCutaway {
    private var surfaces: [(entity: Entity, center: SIMD2<Float>, outward: SIMD2<Float>)] = []

    /// `outline`: floor polygon in scene x/z. With it, "outside" is the side of each wall away from the floor,
    /// which is right for L-shaped rooms; without it, the side away from the room center (fine for boxes only).
    func collect(from room: Entity, outline: [SIMD2<Float>]? = nil) {
        surfaces = []
        let poly = (outline?.count ?? 0) >= 3 ? outline : nil
        func visit(_ e: Entity) {
            if e.name.hasPrefix(RoomBuilder.surfaceName) {
                let p = e.position(relativeTo: nil)
                let z = e.orientation(relativeTo: nil).act([0, 0, 1])
                var n = simd_normalize(SIMD2(z.x, z.z))
                let c = SIMD2(p.x, p.z)
                if let poly, FloorClamp.contains(c + n * 0.3, poly) != FloorClamp.contains(c - n * 0.3, poly) {
                    if FloorClamp.contains(c + n * 0.3, poly) { n = -n }   // floor is on the +n side: outward is -n
                } else if simd_dot(n, c) < 0 { n = -n }   // room is centered on the origin
                surfaces.append((e, SIMD2(p.x, p.z), n))
            }
            e.children.forEach(visit)
        }
        visit(room)
    }

    func update(cameraPosition c: SIMD3<Float>) {
        let cam = SIMD2(c.x, c.z)
        for s in surfaces {
            let outside = simd_dot(cam - s.center, s.outward) > 0.05
            let goal: Float = outside ? 0 : 1
            var now = s.entity.components[OpacityComponent.self]?.opacity ?? 1
            if !s.entity.isEnabled {
                guard !outside else { continue }
                s.entity.isEnabled = true   // camera came back around: fade in from nothing
                now = 0
            }
            guard abs(now - goal) > 0.005 else { continue }
            now += (goal - now) * 0.2
            s.entity.components.set(OpacityComponent(opacity: now))
            // Fully hidden, not ghosted: even a faint textured wall (brick) reads as a pattern on furniture behind it.
            if outside && now < 0.02 { s.entity.isEnabled = false }
        }
    }
}

/// Small capsule hint over the 3D view ("Drag to orbit · Pinch to zoom").
struct HintPill: View {
    let text: String
    var fill = Theme.ground.opacity(0.85)
    var ink = Theme.ink
    init(_ text: String, fill: Color = Theme.ground.opacity(0.85), ink: Color = Theme.ink) {
        self.text = text; self.fill = fill; self.ink = ink
    }
    var body: some View {
        Text(text).font(.forma(11)).foregroundStyle(ink)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(fill, in: Capsule())
    }
}

/// Pill used inside the Objects panel's selected row: outlined, or sage-filled for the suggested action.
private struct PanelLabel: View {
    let title: String, icon: String
    var filled = false
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        Label(title, systemImage: icon).font(.forma(12)).foregroundStyle(filled ? Theme.onSage : Theme.ink)
            .lineLimit(1).minimumScaleFactor(0.85)
            .frame(maxWidth: .infinity, minHeight: 40)
            .background(filled ? Theme.sage : .clear, in: Capsule())
            .overlay { if !filled { Capsule().strokeBorder(Theme.ink, lineWidth: 1) } }
            .contentShape(Capsule())
            .opacity(enabled ? 1 : 0.4)
            .animation(nil, value: title)   // Lock ⇄ Unlock swaps instantly; a cross-fade overlapped the two words
    }
}

private struct PanelAction: View {
    let title: String, icon: String, filled: Bool, action: () -> Void
    init(_ title: String, icon: String, filled: Bool = false, action: @escaping () -> Void) {
        self.title = title; self.icon = icon; self.filled = filled; self.action = action
    }
    var body: some View {
        Button(action: action) { PanelLabel(title: title, icon: icon, filled: filled) }
            .accessibilityLabel(title)
    }
}
