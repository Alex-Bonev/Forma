import SwiftUI
import RealityKit

/// Core demo screen: orbit the dollhouse, drop library objects in, drag/rotate/delete them.
struct DesignerView: View {
    let projectID: UUID
    @Environment(ProjectStore.self) private var store
    @State private var scene = Entity()
    @State private var roomEntity: Entity?
    @State private var roomSize: SIMD2<Float> = .zero
    @State private var placed: [UUID: Entity] = [:]   // placement id -> entity
    @State private var selected: UUID?
    @State private var camera = PerspectiveCamera()
    @State private var orbit = Orbit()
    @State private var viewSize: CGSize = .zero
    @State private var dragMode: DragMode?
    @State private var zoomStart: Float?
    @State private var twistStart: simd_quatf?
    @State private var lowWalls = false

    struct Orbit { var azimuth: Float = 0.55; var elevation: Float = 0.85; var distance: Float = 8 }
    enum DragMode { case orbit(Orbit), move(UUID, SIMD3<Float>) }

    private var project: Project? { store.projects.first { $0.id == projectID } }

    var body: some View {
        if let project, let room = store.room(for: project) {
            realityView(project: project, room: room)
                .navigationTitle(project.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Toggle(isOn: $lowWalls) { Image(systemName: "square.split.bottomrightquarter") }
                            .toggleStyle(.button)
                            .accessibilityLabel("Cutaway walls")
                    }
                }
                .onChange(of: lowWalls) { rebuildRoom(room) }
                .safeAreaInset(edge: .bottom) { bottomPanel(project) }
                .sensoryFeedback(.selection, trigger: selected)
        } else {
            ContentUnavailableView("Room not found", systemImage: "cube.transparent")
        }
    }

    private func realityView(project: Project, room: RoomModel) -> some View {
        RealityView { content in
            content.camera = .virtual
            let sun = DirectionalLight()
            sun.light.intensity = 3000
            sun.shadow = DirectionalLightComponent.Shadow()
            sun.look(at: .zero, from: [2, 5, 3], relativeTo: nil)
            scene.addChild(sun)
            scene.addChild(camera)
            content.add(scene)
            rebuildRoom(room)
            orbit.distance = zoomRange.lowerBound * 1.8
            updateCamera()
            for p in project.placements { await spawn(p) }
        }
        .ignoresSafeArea(edges: .bottom)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { viewSize = $0 }
        .overlay(alignment: .topLeading) {
            Text(String(format: "%.1f × %.1f m", roomSize.x, roomSize.y))
                .font(.footnote.weight(.semibold)).monospacedDigit()
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(.regularMaterial, in: Capsule())
                .padding()
        }
        .gesture(dragGesture)
        .simultaneousGesture(pinchGesture)
        .simultaneousGesture(twistGesture)
        .simultaneousGesture(SpatialTapGesture().onEnded { v in selected = hitPlacement(at: v.location) })
    }

    // MARK: Gestures
    // Own orbit camera instead of .realityViewCameraControls: the built-in controls swallow every
    // touch (objects could not be dragged) and let you zoom through the walls.

    /// One finger: starts on an object -> slide it on the floor (keeping the grab offset); else orbit.
    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { v in
                if dragMode == nil {
                    if let id = hitPlacement(at: v.startLocation), let e = placed[id],
                       let start = floorPoint(at: v.startLocation) {
                        dragMode = .move(id, e.position - start)
                        selected = id
                    } else {
                        dragMode = .orbit(orbit)
                    }
                }
                switch dragMode {
                case .move(let id, let offset):
                    if let p = floorPoint(at: v.location) { placed[id]?.position = clamp(p + offset) }
                case .orbit(let start):
                    orbit.azimuth = start.azimuth - Float(v.translation.width) * 0.008
                    orbit.elevation = min(max(start.elevation + Float(v.translation.height) * 0.005, 0.25), 1.5)
                    updateCamera()
                case nil: break
                }
            }
            .onEnded { _ in
                if case .move = dragMode { commit() }
                dragMode = nil
            }
    }

    private var pinchGesture: some Gesture {
        MagnifyGesture()
            .onChanged { v in
                if zoomStart == nil { zoomStart = orbit.distance }
                let d = zoomStart! / Float(v.magnification)
                orbit.distance = min(max(d, zoomRange.lowerBound), zoomRange.upperBound)
                updateCamera()
            }
            .onEnded { _ in zoomStart = nil }
    }

    /// Two-finger twist rotates the selected object around Y.
    private var twistGesture: some Gesture {
        RotateGesture()
            .onChanged { v in
                guard let selected, let e = placed[selected] else { return }
                if twistStart == nil { twistStart = e.orientation }
                e.orientation = simd_quatf(angle: -Float(v.rotation.radians), axis: [0, 1, 0]) * twistStart!
            }
            .onEnded { _ in
                if twistStart != nil { commit() }
                twistStart = nil
            }
    }

    // MARK: Camera math

    /// Never closer than the room needs to stay in view, never so far it becomes a speck.
    private var zoomRange: ClosedRange<Float> {
        let size = max(roomSize.x, roomSize.y, 2)
        return (size * 0.6 + 1)...(size * 3 + 3)
    }

    private func updateCamera() {
        let o = orbit
        let dir = SIMD3(cos(o.elevation) * sin(o.azimuth), sin(o.elevation), cos(o.elevation) * cos(o.azimuth))
        camera.look(at: .zero, from: dir * o.distance, relativeTo: nil)
    }

    /// World-space ray through a view point, from the camera's pose and vertical field of view.
    private func ray(at point: CGPoint) -> (origin: SIMD3<Float>, direction: SIMD3<Float>) {
        let w = Float(viewSize.width), h = Float(max(viewSize.height, 1))
        let t = tan(camera.camera.fieldOfViewInDegrees * .pi / 360)
        let local = normalize(SIMD3((2 * Float(point.x) / w - 1) * t * w / h, (1 - 2 * Float(point.y) / h) * t, -1))
        return (camera.position(relativeTo: nil), camera.orientation(relativeTo: nil).act(local))
    }

    private func floorPoint(at point: CGPoint) -> SIMD3<Float>? {
        let (o, d) = ray(at: point)
        guard d.y < -0.01 else { return nil }
        let p = o + d * (-o.y / d.y)
        return [p.x, 0, p.z]
    }

    /// Nearest placed object whose (padded) bounding box the ray passes through.
    private func hitPlacement(at point: CGPoint) -> UUID? {
        let (o, d) = ray(at: point)
        var best: (id: UUID, t: Float)?
        for (id, e) in placed {
            let b = e.visualBounds(relativeTo: e)
            let lo = b.min - 0.1, hi = b.max + 0.1   // fat-finger padding
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
                            Label(object.name, systemImage: "plus.circle.fill")
                        }
                        .buttonStyle(.bordered)
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
    }

    private func spawn(_ p: Placement) async {
        guard let object = store.objects.first(where: { $0.id == p.objectID }) else { return }
        let e = await RoomBuilder.placedEntity(for: object, url: store.modelURL(for: object))
        e.name = p.id.uuidString
        e.position = p.position
        e.orientation = simd_quatf(angle: p.yRotation, axis: [0, 1, 0])
        scene.addChild(e)
        placed[p.id] = e
    }

    private func add(_ object: ScannedObject) async {
        guard var project else { return }
        let p = Placement(id: UUID(), objectID: object.id, position: .zero, yRotation: 0)
        project.placements.append(p)
        store.update(project)
        await spawn(p)
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
    private func clamp(_ p: SIMD3<Float>) -> SIMD3<Float> {
        let h = roomSize / 2
        return [min(max(p.x, -h.x), h.x), 0, min(max(p.z, -h.y), h.y)]
    }
}
