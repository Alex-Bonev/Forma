import SwiftUI
import RealityKit
/// Core demo screen: orbit the dollhouse, drop library objects in, drag/rotate/delete them.
///
/// Touch model (all on `TouchSurface`):
/// - one finger on an object: slide it on the floor · one finger elsewhere: orbit (flick for momentum)
/// - two fingers: pan · pinch: zoom · twist: rotate the selected object (or the view if none)
/// - tap: select / deselect
struct DesignerView: View {
    let projectID: UUID
    @Environment(ProjectStore.self) private var store
    @State private var scene = Entity()
    @State private var camera = OrbitCamera()
    @State private var walls = WallCutaway()
    @State private var roomEntity: Entity?
    @State private var roomSize: SIMD2<Float> = .zero
    @State private var outline: [SIMD3<Float>]?   // scanned floor polygon, room coordinates (cached: room(for:) reads disk)
    @State private var placed: [UUID: Entity] = [:]   // placement id -> entity
    @State private var selected: UUID?
    @State private var selectedRoomObject: Int?   // index into the scan's RoomPlan objects
    @State private var highlighted: Entity?
    @State private var showCatalog = false
    @State private var editing = false
    @State private var showPhotos = false
    @State private var scanTarget: ScanTarget?
    @State private var render: RenderRequest?   // "Make it real" sheet input
    @State private var undo: (title: String, snapshot: Project)?   // last Delete / Hide, offered for a few seconds
    @State private var naturalSize: [UUID: SIMD3<Float>] = [:]   // placement id -> unscaled model size (m)

    /// What a new Object Capture scan should replace.
    enum ScanTarget: Identifiable {
        case placement(UUID), roomObject(Int)
        var id: String { switch self { case .placement(let u): u.uuidString; case .roomObject(let i): "room-\(i)" } }
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

    var body: some View {
        if let project, let room = store.room(for: project) {
            realityView(project: project, room: room)
                .navigationTitle(nameBinding)   // tap the title > Rename
                .navigationBarTitleDisplayMode(.inline)
                .toolbarRole(.editor)
                .onChange(of: lowWalls) { rebuildRoom(room) }
                .onChange(of: realisticFurniture) { rebuildRoom(room) }
                .onChange(of: selected) { _, new in
                    if new != nil { undo = nil; selectedRoomObject = nil }
                    highlight(new.flatMap { placed[$0] })
                }
                .onChange(of: selectedRoomObject) { _, new in
                    if new != nil { undo = nil; selected = nil }
                    highlight(new.flatMap(roomObjectEntity))
                }
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Make it real", systemImage: "sparkles") { Task { await makeItReal() } }
                    }
                }
                .sheet(item: $render) { r in RenderView(snapshot: r.snapshot, projectID: projectID, camera: r.camera) }
                .sheet(isPresented: $showCatalog) { catalogSheet }
                .sheet(isPresented: $showPhotos) { RoomPhotosView(projectID: projectID) }
                .sheet(isPresented: $editing) { if let selected { editor(selected) } }
                .fullScreenCover(item: $scanTarget) { target in
                    ObjectScanView { object in Task { await applyScan(object, to: target) } }
                }
                .safeAreaInset(edge: .bottom) { bottomPanel(project) }
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
        .ignoresSafeArea(edges: .bottom)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { viewSize = $0 }
        .overlay {
            TouchSurface(handlers: touchHandlers, accessibilityValue: selectionDescription(project))
                .ignoresSafeArea(edges: .bottom)
        }
        .overlay(alignment: .topLeading) {
            Text(String(format: "%.1f × %.1f m", roomSize.x, roomSize.y))
                .font(.footnote.weight(.semibold)).monospacedDigit()
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(.regularMaterial, in: Capsule())
                .padding()
        }
        .overlay(alignment: .topTrailing) { viewControls.padding() }
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
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
            let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard var p = project, !name.isEmpty else { return }
            p.name = name
            store.update(p)
        })
    }

    private func finishBinding(_ key: WritableKeyPath<Project, String?>, default d: String) -> Binding<String> {
        Binding(
            get: { project?[keyPath: key] ?? d },
            set: { id in
                guard var p = project, let room = roomEntity else { return }
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
        guard let selected, let p = project.placements.first(where: { $0.id == selected }),
              let name = CatalogItem.item(p.catalogItem)?.name ?? store.objects.first(where: { $0.id == p.objectID })?.name
        else { return nil }
        return String(format: "%@ at %.2f, %.2f m", name, p.position.x, p.position.z)
    }

    // MARK: Touch

    private var touchHandlers: TouchSurface.Handlers {
        var h = TouchSurface.Handlers()
        h.touchDown = {
            camera.grab()
            if showHint { showHint = false }
        }
        h.touchUp = { camera.release() }
        h.oneFinger = { phase, location, delta, velocity in
            switch phase {
            case .began:
                if let id = hitPlacement(at: location), let e = placed[id],
                   let start = floorPoint(at: location) {
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
            if phase == .began { twistingObject = selected != nil }
            if twistingObject, let selected, let e = placed[selected] {
                if phase == .ended { commit() }
                else { e.orientation = simd_quatf(angle: -Float(delta), axis: [0, 1, 0]) * e.orientation }
            } else if phase != .ended {
                camera.twist(by: delta)
            }
            if phase == .ended { twistingObject = false }
        }
        h.tap = { location in
            if let id = hitPlacement(at: location) { selected = id }
            else if let i = hitRoomObject(at: location) { selected = nil; selectedRoomObject = i }
            else { selected = nil; selectedRoomObject = nil }
        }
        return h
    }

    private func floorPoint(at point: CGPoint) -> SIMD3<Float>? {
        guard let (o, d) = content?.ray(through: point, in: .local, to: .scene), d.y < -0.01 else { return nil }
        let p = o + d * (-o.y / d.y)
        return [p.x, 0, p.z]
    }

    /// Nearest placed object whose (padded) bounding box the ray passes through.
    private func hitPlacement(at point: CGPoint) -> UUID? {
        guard let (o, d) = content?.ray(through: point, in: .local, to: .scene) else { return nil }
        var best: (id: UUID, t: Float)?
        for (id, e) in placed {
            let b = e.visualBounds(relativeTo: e)
            let lo = b.min - 0.12, hi = b.max + 0.12   // fat-finger padding
            let ro = e.convert(position: o, from: nil), rd = e.convert(direction: d, from: nil)
            var tmin: Float = 0, tmax = Float.greatestFiniteMagnitude
            for i in 0..<3 {
                var t0 = (lo[i] - ro[i]) / rd[i], t1 = (hi[i] - ro[i]) / rd[i]
                if t0 > t1 { swap(&t0, &t1) }
                tmin = max(tmin, t0); tmax = min(tmax, t1)
            }
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

    // MARK: Panel

    @ViewBuilder private func bottomPanel(_ project: Project) -> some View {
        VStack(spacing: 12) {
            if showHint || objectHint {
                Text(objectHint ? "Drag to move · Twist with two fingers to rotate"
                                : "Drag to look around · Two fingers to pan · Pinch to zoom")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }
            if let undo {
                HStack {
                    Text(undo.title).font(.subheadline.weight(.medium))
                    Spacer()
                    Button("Undo", systemImage: "arrow.uturn.backward") { restore(undo.snapshot) }
                        .buttonStyle(.bordered)
                }
                .padding(.horizontal)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if let i = selectedRoomObject, let room = store.room(for: project), room.objects.indices.contains(i) {
                roomObjectCard(i, room: room)
            } else if let selected, placed[selected] != nil {
                placementCard(selected, project: project)
            } else if let hidden = project.hiddenRoomObjects, !hidden.isEmpty {
                Button("Show \(hidden.count) hidden scanned item\(hidden.count == 1 ? "" : "s")") { restoreHidden() }
                    .font(.footnote)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    Button { showCatalog = true } label: { Label("Add Item", systemImage: "plus.square.on.square") }
                        .buttonStyle(.borderedProminent)
                    ForEach(store.objects) { object in
                        Button { Task { await add(object) } } label: {
                            if adding == object.name {
                                HStack(spacing: 6) { ProgressView().controlSize(.small); Text(object.name) }
                            } else {
                                Label(object.name, systemImage: "plus.circle.fill")
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(adding != nil)
                    }
                }
                .padding(.horizontal)
            }
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial)
        .animation(.spring(duration: 0.3, bounce: 0), value: selected)
        .animation(.spring(duration: 0.3, bounce: 0), value: selectedRoomObject)
        .animation(.spring(duration: 0.3, bounce: 0), value: undo?.title)
    }

    // MARK: Selection cards
    // One card per selection: name + at most 4 labeled actions. Move = drag, rotate = twist, deselect = tap empty space.

    private func placementCard(_ id: UUID, project: Project) -> some View {
        selectionCard(title: selectionDescription(project)?.components(separatedBy: " at ").first ?? "Item",
                      subtitle: "Drag to move · Twist to rotate") {
            ActionButton("Size", icon: "slider.horizontal.3") { editing = true }
            if Capabilities.canScanObject {
                ActionButton("Scan Real", icon: "camera.viewfinder") { scanTarget = .placement(id) }
            }
            ActionButton("Delete", icon: "trash", role: .destructive) { remove(id) }
        }
    }

    private func roomObjectCard(_ i: Int, room: RoomModel) -> some View {
        let box = room.objects[i]
        let marked = box.label == RoomModel.markedLabel
        // Vision suggestion for marked items (SceneClassifier), offered as the first action.
        let suggestion = CatalogItem.item(box.attributes?.first { $0.hasPrefix("Suggest.") }.map { String($0.dropFirst(8)) })
        return selectionCard(title: marked ? "Marked Item" : "Scanned \(box.label.capitalized)",
                             subtitle: suggestion.map { "Looks like a \($0.name)" } ?? "From your room scan") {
            if let suggestion {
                ActionButton("Use \(suggestion.name)", icon: suggestion.symbol, prominent: true) {
                    Task { await replaceRoomObject(i, catalog: suggestion) }
                }
            }
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
            } label: { ActionLabel(title: "Replace", icon: "arrow.triangle.2.circlepath") }
                .accessibilityLabel("Replace")
            if !marked {
                ActionButton("Size", icon: "slider.horizontal.3") { Task { await editRoomObject(i, room: room) } }
            }
            if Capabilities.canScanObject {
                ActionButton("Scan Real", icon: "camera.viewfinder") { scanTarget = .roomObject(i) }
            }
            ActionButton("Hide", icon: "eye.slash") { hideRoomObject(i) }
        }
    }

    private func selectionCard<Actions: View>(title: String, subtitle: String,
                                              @ViewBuilder actions: () -> Actions) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            .lineLimit(1)
            HStack(spacing: 8) { actions() }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var catalogSheet: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 12)], spacing: 12) {
                    ForEach(CatalogItem.all) { item in
                        Button {
                            showCatalog = false
                            Task { await add(catalog: item) }
                        } label: {
                            VStack(spacing: 8) {
                                Image(systemName: item.symbol).font(.title2).frame(height: 30)
                                Text(item.name).font(.footnote.weight(.medium)).lineLimit(1)
                                Text(String(format: "%.1f × %.1f m", item.size.x, item.size.z))
                                    .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                            }
                            .frame(maxWidth: .infinity).padding(.vertical, 14)
                            .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
            }
            .navigationTitle("Add Item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showCatalog = false } } }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: Actions

    private func rebuildRoom(_ room: RoomModel) {
        roomEntity?.removeFromParent()
        let built = RoomBuilder.build(room, wallScale: lowWalls ? 0.3 : 1)
        scene.addChild(built.entity)
        roomEntity = built.entity
        roomSize = built.size
        outline = room.floorOutline
        walls.collect(from: built.entity)
        for i in (project?.hiddenRoomObjects ?? []) + (project?.removedRoomObjects ?? []) { roomObjectEntity(i)?.isEnabled = false }
        let wall = Finish.wall(project?.wallFinish), floor = Finish.floor(project?.floorFinish)
        Task {
            await Finish.apply(to: built.entity, wall: wall, floor: floor)
            await RoomBuilder.furnish(built, room: room)
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
        naturalSize[p.id] = e.visualBounds(relativeTo: e).extents
        placed[p.id]?.removeFromParent()   // never two entities for one placement
        e.name = p.id.uuidString
        e.position = p.position
        e.orientation = simd_quatf(angle: p.yRotation, axis: [0, 1, 0])
        e.scale = p.scale ?? .one
        scene.addChild(e)
        placed[p.id] = e
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
        if let e = placed[p.id] { e.position = clamp(e.position, keeping: e); commit() }
        selected = p.id
        objectHint = true
        try? await Task.sleep(for: .seconds(4))
        objectHint = false
    }

    private func add(catalog item: CatalogItem) async {
        guard var project else { return }
        let p = Placement(id: UUID(), objectID: Placement.catalogObjectID, position: clamp(camera.goal.target),
                          yRotation: 0, catalogItem: item.id)
        project.placements.append(p)
        store.update(project)
        await spawn(p)
        if let e = placed[p.id] { e.position = clamp(e.position, keeping: e); commit() }
        selected = p.id
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
        editing = true
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

    /// Size (per axis) and mounting height of the selected placement, applied live.
    private func editor(_ id: UUID) -> some View {
        NavigationStack {
            Form {
                Section("Size") {
                    dimensionRow("Width", id: id, axis: 0)
                    dimensionRow("Height", id: id, axis: 1)
                    dimensionRow("Depth", id: id, axis: 2)
                    Button("Reset Size") { setScale(id) { _ in fitScale(id) } }
                }
                Section {
                    LabeledContent("Height above floor", value: String(format: "%.2f m", elevation(id)))
                    Slider(value: Binding(get: { Double(elevation(id)) }, set: { setElevation(id, Float($0)) }), in: 0...2.4, step: 0.01)
                    Button("Put on Floor") { setElevation(id, 0) }
                } header: { Text("Mounting") } footer: {
                    Text("Raise wall-mounted items like sinks, shelves, TVs or lamps.")
                }
            }
            .navigationTitle(selectionDescription(project!)?.components(separatedBy: " at ").first ?? "Edit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { editing = false } } }
        }
        .presentationDetents([.medium])
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
    }

    private func dimensionRow(_ title: String, id: UUID, axis: Int) -> some View {
        let natural = naturalSize[id] ?? .one
        let size = natural * baseScale(id)
        return Stepper(value: Binding(
            get: { Double(size[axis]) },
            set: { v in setScale(id) { s in var s = s; s[axis] = max(Float(v), 0.05) / max(natural[axis], 0.001); return s } }
        ), in: 0.05...6, step: 0.05) {
            LabeledContent(title, value: String(format: "%.2f m", size[axis]))
        }
    }

    private func setScale(_ id: UUID, _ change: (SIMD3<Float>) -> SIMD3<Float>) {
        guard var project, let k = project.placements.firstIndex(where: { $0.id == id }) else { return }
        let s = change(project.placements[k].scale ?? .one)
        guard s != (project.placements[k].scale ?? .one) else { return }
        project.placements[k].scale = s == .one ? nil : s
        store.update(project)
        placed[id]?.scale = s
        if let e = placed[id] { highlight(e) }   // resize the selection disc
    }

    private func fitScale(_ id: UUID) -> SIMD3<Float> { project?.placements.first { $0.id == id }?.fitScale ?? .one }

    private func elevation(_ id: UUID) -> Float { project?.placements.first { $0.id == id }?.position.y ?? 0 }

    private func setElevation(_ id: UUID, _ y: Float) {
        guard var project, let k = project.placements.firstIndex(where: { $0.id == id }) else { return }
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
        for i in project.hiddenRoomObjects ?? [] { roomObjectEntity(i)?.isEnabled = true }
        project.hiddenRoomObjects = nil
        store.update(project)
    }


    private func remove(_ id: UUID) {
        guard var project else { return }
        offerUndo("Deleted", project)
        placed.removeValue(forKey: id)?.removeFromParent()
        project.placements.removeAll { $0.id == id }
        store.update(project)
        selected = nil
    }

    struct RenderRequest: Identifiable { let id = UUID(); let snapshot: UIImage; let camera: RenderCamera }

    /// Snapshot the 3D view (selection markers cleared first) and open David's RenderView.
    private func makeItReal() async {
        selected = nil
        selectedRoomObject = nil
        try? await Task.sleep(for: .milliseconds(150))   // let RealityKit draw a frame without the brackets
        guard let snap = captureDesignerSnapshot() else { return }
        let cam = RenderCamera(transform: camera.entity.transformMatrix(relativeTo: nil),
                               verticalFOV: camera.entity.camera.fieldOfViewInDegrees,
                               viewSize: viewSize, wallScale: lowWalls ? 0.3 : 1)
        render = RenderRequest(snapshot: snap, camera: cam)
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
        let gone = Set((snapshot.hiddenRoomObjects ?? []) + (snapshot.removedRoomObjects ?? []))
        for i in (store.room(for: snapshot)?.objects.indices ?? 0..<0) { roomObjectEntity(i)?.isEnabled = !gone.contains(i) }
        for p in snapshot.placements where placed[p.id] == nil { Task { await spawn(p) } }
    }

    /// Selection marker: blue corner brackets around the object's bounds plus a soft disc on the floor.
    /// Parented to the object so it follows drags; bar thickness divides out the object's scale.
    private func highlight(_ e: Entity?) {
        highlighted?.findEntity(named: "selection")?.removeFromParent()
        highlighted = e
        guard let e else { return }
        let b = e.visualBounds(relativeTo: e)
        let marker = Entity()
        marker.name = "selection"
        var m = UnlitMaterial(color: .systemBlue)
        m.blending = .transparent(opacity: 0.35)
        let radius = max(b.extents.x, b.extents.z) / 2 + 0.12
        let disc = ModelEntity(mesh: .generateCylinder(height: 0.004, radius: radius), materials: [m])
        // On the floor: placements have their origin there; scanned furniture is anchored at its box center.
        disc.position = [b.center.x, (0.003 - e.position(relativeTo: scene).y) / e.scale.y, b.center.z]
        marker.addChild(disc)

        let pad: Float = 0.05, t: Float = 0.03
        var lo = b.min - pad, hi = b.max + pad
        lo.y = b.min.y + t / 2   // bottom brackets sit on the floor, not in it
        let size = hi - lo
        let bar = UnlitMaterial(color: .systemBlue)
        for corner in 0..<8 {
            let c = SIMD3<Float>(corner & 1 == 0 ? lo.x : hi.x, corner & 2 == 0 ? lo.y : hi.y, corner & 4 == 0 ? lo.z : hi.z)
            for axis in 0..<3 {
                let len = min(0.3, size[axis] * 0.35)
                var dims = SIMD3<Float>(repeating: t) / e.scale
                dims[axis] = len
                var pos = c
                pos[axis] += (c[axis] == lo[axis] ? 1 : -1) * len / 2   // run inward from the corner
                let piece = ModelEntity(mesh: .generateBox(size: dims), materials: [bar])
                piece.position = pos
                marker.addChild(piece)
            }
        }
        e.addChild(marker)
    }

    /// Write entity transforms back to the project. `rotation` overrides an in-flight animation.
    private func commit(rotation: (Entity, simd_quatf)? = nil) {
        guard var project else { return }
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
            xz = FloorClamp.clamp(xz, to: poly, inset: max(half.x, half.y) + RoomBuilder.wallThickness / 2)
        }
        return [xz.x, max(p.y, 0), xz.y]   // y = mounting height
    }
}

/// Dollhouse cutaway: walls (and their doors/windows) between the camera and the room fade out, so the
/// interior is always visible from any orbit angle. Plain class: runs every frame.
@MainActor
final class WallCutaway {
    private var surfaces: [(entity: Entity, center: SIMD2<Float>, outward: SIMD2<Float>)] = []

    func collect(from room: Entity) {
        surfaces = []
        func visit(_ e: Entity) {
            if e.name.hasPrefix(RoomBuilder.surfaceName) {
                let p = e.position(relativeTo: nil)
                let z = e.orientation(relativeTo: nil).act([0, 0, 1])
                var n = simd_normalize(SIMD2(z.x, z.z))
                if simd_dot(n, SIMD2(p.x, p.z)) < 0 { n = -n }   // room is centered on the origin
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

/// Icon over a short caption: every action says what it does.
struct ActionLabel: View {
    let title: String
    let icon: String
    var prominent = false
    var role: ButtonRole? = nil

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 18, weight: .medium))
            Text(title).font(.caption.weight(.medium)).lineLimit(1).minimumScaleFactor(0.8)
        }
        .foregroundStyle(prominent ? AnyShapeStyle(.white) : role == .destructive ? AnyShapeStyle(.red) : AnyShapeStyle(.tint))
        .frame(maxWidth: .infinity, minHeight: 54)
        .background(prominent ? AnyShapeStyle(.tint) : AnyShapeStyle(.fill.tertiary),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 12))
    }
}

struct ActionButton: View {
    let title: String
    let icon: String
    var prominent = false
    var role: ButtonRole? = nil
    let action: () -> Void

    init(_ title: String, icon: String, prominent: Bool = false, role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.title = title; self.icon = icon; self.prominent = prominent; self.role = role; self.action = action
    }

    var body: some View {
        Button(role: role, action: action) { ActionLabel(title: title, icon: icon, prominent: prominent, role: role) }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
    }
}
