import SwiftUI
import RealityKit
import os

private let log = Logger(subsystem: "RoomVibe", category: "Designer")

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
    @State private var placed: [UUID: Entity] = [:]   // placement id -> entity
    @State private var selected: UUID?
    @State private var moving: (id: UUID, offset: SIMD3<Float>)?
    @State private var viewSize: CGSize = .zero
    @State private var lowWalls = false
    @State private var topView = false
    @State private var showHint = true
    @State private var adding: String?
    // Kept for picking: RealityKit's own ray(through:) matches its real render surface, which is taller than the
    // SwiftUI frame (it extends under the bottom panel), so hand-rolled projection from the frame missed objects.
    @State private var content: RealityViewCameraContent?

    private var project: Project? { store.projects.first { $0.id == projectID } }

    var body: some View {
        if let project, let room = store.room(for: project) {
            realityView(project: project, room: room)
                .navigationTitle(project.name)
                .navigationBarTitleDisplayMode(.inline)
                .onChange(of: lowWalls) { rebuildRoom(room) }
                .onChange(of: selected) { old, new in highlight(old: old, new: new) }
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
            camera.updates = content.subscribe(to: SceneEvents.Update.self) { e in
                MainActor.assumeIsolated { cam.update(dt: Float(e.deltaTime)) }
            }
            for p in project.placements { await spawn(p) }
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
        .overlay(alignment: .top) {
            if showHint {
                Text("Drag to look around · Two fingers to pan · Pinch to zoom")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, 56)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.3), value: showHint)
    }

    /// Maps-style floating controls.
    private var viewControls: some View {
        VStack(spacing: 0) {
            controlButton("scope", label: "Reset view") { camera.reset(); topView = false }
            Divider().frame(width: 28)
            controlButton(topView ? "view.3d" : "square.grid.3x3.topleft.filled", label: topView ? "3D view" : "Top view") {
                camera.toggleTopView(); topView = camera.isTopView
            }
            Divider().frame(width: 28)
            controlButton(lowWalls ? "square.split.bottomrightquarter.fill" : "square.split.bottomrightquarter",
                          label: lowWalls ? "Full walls" : "Cutaway walls") { lowWalls.toggle() }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
              let name = store.objects.first(where: { $0.id == p.objectID })?.name else { return nil }
        return String(format: "%@ at %.2f, %.2f m", name, p.position.x, p.position.z)
    }

    // MARK: Touch

    private var touchHandlers: TouchSurface.Handlers {
        var h = TouchSurface.Handlers()
        h.touchDown = {
            camera.stopMomentum()
            if showHint { showHint = false }
        }
        h.oneFinger = { phase, location, delta, velocity in
            switch phase {
            case .began:
                if let id = hitPlacement(at: location), let e = placed[id],
                   let start = floorPoint(at: location) {
                    moving = (id, e.position - start)
                    selected = id
                    e.scale = [1.04, 1.04, 1.04]   // lifted while dragged
                }
            case .changed:
                if let moving, let e = placed[moving.id] {
                    if let p = floorPoint(at: location) { e.position = clamp(p + moving.offset, keeping: e) }
                } else {
                    camera.orbit(by: delta)
                    if topView { topView = camera.isTopView }
                }
            case .ended:
                if let moving {
                    placed[moving.id]?.scale = .one
                    self.moving = nil
                    commit()
                } else {
                    camera.endOrbit(velocity: velocity)
                }
            }
        }
        h.twoFingerPan = { delta in
            if moving == nil { camera.pan(by: delta, viewHeight: viewSize.height) }
        }
        h.pinch = { phase, scale in
            switch phase {
            case .began: camera.beginZoom()
            case .changed: camera.zoom(scale: scale)
            case .ended: break
            }
        }
        h.twist = { phase, delta in
            if let selected, let e = placed[selected] {
                if phase == .ended { commit() }
                else { e.orientation = simd_quatf(angle: -Float(delta), axis: [0, 1, 0]) * e.orientation }
            } else if phase != .ended {
                camera.twist(by: delta)
            }
        }
        h.tap = { location in selected = hitPlacement(at: location) }
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

    // MARK: Panel

    @ViewBuilder private func bottomPanel(_ project: Project) -> some View {
        VStack(spacing: 12) {
            if let selected, let e = placed[selected] {
                HStack(spacing: 20) {
                    Button { rotate(e, by: -.pi / 8) } label: { Image(systemName: "rotate.left") }
                        .accessibilityLabel("Rotate left")
                    Button { rotate(e, by: .pi / 8) } label: { Image(systemName: "rotate.right") }
                        .accessibilityLabel("Rotate right")
                    Button(role: .destructive) { remove(selected) } label: { Image(systemName: "trash") }
                        .accessibilityLabel("Remove")
                    Button("Done") { self.selected = nil }
                }
                .font(.title3)
                .buttonStyle(.bordered)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    if store.objects.isEmpty {
                        Text("Object library is empty. Scan an object or load demo data.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
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
    }

    // MARK: Actions

    private func rebuildRoom(_ room: RoomModel) {
        roomEntity?.removeFromParent()
        let built = RoomBuilder.build(room, wallScale: lowWalls ? 0.3 : 1)
        scene.addChild(built.entity)
        roomEntity = built.entity
        roomSize = built.size
        walls.collect(from: built.entity)
    }

    private func spawn(_ p: Placement) async {
        guard let object = store.objects.first(where: { $0.id == p.objectID }) else {
            log.error("placement \(p.id) references missing object \(p.objectID)")
            return
        }
        let e = await RoomBuilder.placedEntity(for: object, url: store.modelURL(for: object))
        log.info("spawned \(object.name, privacy: .public) extents \(e.visualBounds(relativeTo: e).extents, privacy: .public)")
        e.name = p.id.uuidString
        e.position = p.position
        e.orientation = simd_quatf(angle: p.yRotation, axis: [0, 1, 0])
        scene.addChild(e)
        placed[p.id] = e
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
    }

    private func rotate(_ e: Entity, by angle: Float) {
        var t = e.transform
        t.rotation = simd_quatf(angle: angle, axis: [0, 1, 0]) * t.rotation
        e.move(to: t, relativeTo: e.parent, duration: 0.25, timingFunction: .easeInOut)
        commit(rotation: (e, t.rotation))
    }

    private func remove(_ id: UUID) {
        guard var project else { return }
        placed.removeValue(forKey: id)?.removeFromParent()
        project.placements.removeAll { $0.id == id }
        store.update(project)
        selected = nil
    }

    /// Soft disc on the floor under the selected object.
    private func highlight(old: UUID?, new: UUID?) {
        if let old { placed[old]?.findEntity(named: "selection")?.removeFromParent() }
        guard let new, let e = placed[new] else { return }
        let b = e.visualBounds(relativeTo: e)
        let radius = max(b.extents.x, b.extents.z) / 2 + 0.12
        var m = UnlitMaterial(color: .systemBlue)
        m.blending = .transparent(opacity: 0.4)
        let disc = ModelEntity(mesh: .generateCylinder(height: 0.004, radius: radius), materials: [m])
        disc.name = "selection"
        disc.position.y = 0.003
        e.addChild(disc)
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

    // ponytail: clamps to the room's bounding rectangle, not the actual wall polygon (L-shaped rooms leak).
    /// Keeps `entity`'s footprint (not just its center) inside the walls.
    private func clamp(_ p: SIMD3<Float>, keeping entity: Entity? = nil) -> SIMD3<Float> {
        var r: Float = 0
        if let entity {
            let b = entity.visualBounds(relativeTo: entity.parent)
            r = max(b.extents.x, b.extents.z) / 2
        }
        let h = simd_max(roomSize / 2 - r - RoomBuilder.wallThickness / 2, .zero)
        return [min(max(p.x, -h.x), h.x), 0, min(max(p.z, -h.y), h.y)]
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
            if e.name == RoomBuilder.surfaceName {
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
            let goal: Float = outside ? 0.07 : 1
            let now = s.entity.components[OpacityComponent.self]?.opacity ?? 1
            guard abs(now - goal) > 0.005 else { continue }
            s.entity.components.set(OpacityComponent(opacity: now + (goal - now) * 0.2))
        }
    }
}
