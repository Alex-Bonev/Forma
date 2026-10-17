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
    @State private var dragOffset: SIMD3<Float>?
    @State private var lowWalls = false

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
            content.add(scene)
            rebuildRoom(room)
            // 3/4 overhead "dollhouse" start; orbit controls take over from here.
            let camera = PerspectiveCamera()
            let d = max(roomSize.x, roomSize.y) * 1.6 + 1.5
            camera.look(at: .zero, from: [d * 0.5, d, d * 0.8], relativeTo: nil)
            scene.addChild(camera)
            content.cameraTarget = scene
            for p in project.placements { await spawn(p) }
        }
        .realityViewCameraControls(.orbit)
        .overlay(alignment: .topLeading) {
            Text(String(format: "%.1f × %.1f m", roomSize.x, roomSize.y))
                .font(.footnote.weight(.semibold)).monospacedDigit()
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(.regularMaterial, in: Capsule())
                .padding()
        }
        .gesture(dragGesture)
        .simultaneousGesture(SpatialTapGesture().targetedToAnyEntity().onEnded { v in
            selected = placementID(of: v.entity)
        })
        .ignoresSafeArea(edges: .bottom)
    }

    // Drag on a placed object: slide it along the floor, keeping the grab offset.
    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 4).targetedToAnyEntity()
            .onChanged { v in
                guard let id = placementID(of: v.entity), let e = placed[id],
                      // Floor plane = identity transform (y-up normal at y = 0).
                      // VERIFY: unproject treats planeTransform's Y axis as the normal, as ARView does.
                      let hit = v.unproject(v.location, from: .local, to: .scene, ontoPlane: matrix_identity_float4x4)
                else { return }
                selected = id
                let point = SIMD3(hit.x, 0, hit.z)
                if dragOffset == nil { dragOffset = e.position - point }
                e.position = clamp(point + (dragOffset ?? .zero))
            }
            .onEnded { _ in
                dragOffset = nil
                commit()
            }
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

    private func placementID(of entity: Entity) -> UUID? {
        var e: Entity? = entity
        while let cur = e {
            if let id = UUID(uuidString: cur.name), placed[id] != nil { return id }
            e = cur.parent
        }
        return nil
    }

    // ponytail: clamps to the room's bounding rectangle, not the actual wall polygon (L-shaped rooms leak).
    private func clamp(_ p: SIMD3<Float>) -> SIMD3<Float> {
        let h = roomSize / 2
        return [min(max(p.x, -h.x), h.x), 0, min(max(p.z, -h.y), h.y)]
    }
}
