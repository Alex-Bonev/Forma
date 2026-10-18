import SwiftUI
import RealityKit

/// Paper "G · Object detail", "H · Object fullscreen 3D" and "I · Add to room".
struct ObjectDetailView: View {
    let objectID: UUID
    @Environment(ProjectStore.self) private var store
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var fullscreen = false
    @State private var picking = false
    @State private var rescanning = false

    private var object: ScannedObject? { store.objects.first { $0.id == objectID } }

    var body: some View {
        if let object {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    DetailBar(backTitle: "Library", actionTitle: "Rescan", actionIcon: "arrow.clockwise",
                              actionDisabled: !Capabilities.canScanObject,
                              back: { dismiss() }, action: { rescanning = true })
                    NameField(text: $name, commit: rename)
                    HStack {
                        Measure(label: "Width", value: cm(object.boundingBox.x))
                        Measure(label: "Depth", value: cm(object.boundingBox.z))
                        Measure(label: "Height", value: cm(object.boundingBox.y))
                    }
                    StageCard { ObjectStage(object: object, fullscreen: false) { fullscreen = true } }
                    Button { picking = true } label: { Label("Add to room", systemImage: "plus") }
                        .buttonStyle(PillButtonStyle())
                        .disabled(store.projects.isEmpty)
                    if store.projects.isEmpty {
                        Text("Scan or load a room first, then place this object in it.")
                            .font(.forma(11)).foregroundStyle(Theme.muted)
                    }
                }
                .padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.ground.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .onAppear { name = object.name }
            .fullScreenCover(isPresented: $fullscreen) {
                ObjectStage(object: object, fullscreen: true) { fullscreen = false }
            }
            .sheet(isPresented: $picking) {
                AddToRoomSheet(objectName: object.name) { project in add(object, to: project) }
            }
            .fullScreenCover(isPresented: $rescanning) {
                ObjectScanView { fresh in replace(object, with: fresh) }
            }
        } else {
            ContentUnavailableView("Object not found", systemImage: "chair.lounge")
        }
    }

    private func cm(_ meters: Float) -> String { String(format: "%.0f cm", meters * 100) }

    private func rename() {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let object, !n.isEmpty, n != object.name else { name = object?.name ?? name; return }
        store.rename(object, to: n)
    }

    /// Place at the room's center, then open the room ("Back" returns to the library, as in Paper J).
    private func add(_ object: ScannedObject, to project: Project) {
        var p = project
        let placement = Placement(id: UUID(), objectID: object.id, position: .zero, yRotation: 0)
        p.placements.append(placement)
        store.update(p)
        picking = false
        // Let the sheet finish dismissing first; pushing while it animates leaves the new screen's 3D view blank.
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            router.path.removeAll()   // pop to Home, then push: replacing the path in one step leaves the 3D card blank
            try? await Task.sleep(for: .milliseconds(450))
            router.path = [.room(project.id, added: placement.id)]
        }
    }

    /// The new scan takes over the old one's placements and name; the old model is deleted.
    private func replace(_ old: ScannedObject, with fresh: ScannedObject) {
        store.rename(fresh, to: old.name)
        for var project in store.projects where project.placements.contains(where: { $0.objectID == old.id }) {
            for i in project.placements.indices where project.placements[i].objectID == old.id {
                project.placements[i].objectID = fresh.id
            }
            store.update(project)
        }
        store.delete(old)
        router.path = router.path.map { $0 == .object(old.id) ? .object(fresh.id) : $0 }
    }
}

/// Orbitable, zoomable preview of one scanned object on a dashed turntable ring.
/// Inline it's the card with an expand button; fullscreen it fills the screen with a collapse button.
struct ObjectStage: View {
    let object: ScannedObject
    let fullscreen: Bool
    let toggle: () -> Void
    @Environment(ProjectStore.self) private var store
    @State private var camera = Entity()
    @State private var azimuth: Float = 0.6
    @State private var elevation: Float = 0.45
    @State private var distance: Float = 2.4
    @State private var dragStart: (Float, Float)?
    @State private var zoomStart: Float?

    var body: some View {
        ZStack {
            if fullscreen { Color(hex: 0xE8DFD3).ignoresSafeArea() }
            ring
            RealityView { content in
                content.camera = .virtual
                let sun = DirectionalLight()
                sun.light.intensity = 3500
                sun.look(at: .zero, from: [1.5, 3, 2], relativeTo: nil)
                content.add(sun)
                let model = await RoomBuilder.placedEntity(for: object, url: store.modelURL(for: object))
                let b = model.visualBounds(relativeTo: nil)
                let fit = 1.0 / max(b.extents.max(), 0.01)   // normalise so any size fills the stage
                model.scale = .one * fit
                model.position.y = -b.extents.y * fit / 2
                content.add(model)
                let cam = PerspectiveCamera()
                camera = cam
                content.add(cam)
                place()
            }
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { v in
                    let s = dragStart ?? (azimuth, elevation)
                    dragStart = s
                    azimuth = s.0 - Float(v.translation.width) * 0.01
                    elevation = min(max(s.1 + Float(v.translation.height) * 0.006, 0.05), 1.4)
                    place()
                }
                .onEnded { _ in dragStart = nil })
            .simultaneousGesture(MagnifyGesture()
                .onChanged { v in
                    let z = zoomStart ?? distance
                    zoomStart = z
                    distance = min(max(z / Float(v.magnification), 1.2), 5)
                    place()
                }
                .onEnded { _ in zoomStart = nil })
            .accessibilityLabel("\(object.name) 3D view")
        }
        .overlay(alignment: .topLeading) { if fullscreen { collapse } }
        .overlay(alignment: .topTrailing) {
            if fullscreen {
                Text(object.name).font(.forma(12, bold: true)).foregroundStyle(Theme.ink)
                    .padding(.horizontal, 14).frame(height: 32).background(Theme.ground.opacity(0.9), in: Capsule())
                    .padding(.top, 16).padding(.trailing, 16)
            } else { expand }
        }
        .overlay(alignment: .bottom) { HintPill("Drag to orbit · Pinch to zoom").padding(.bottom, fullscreen ? 36 : 12) }
    }

    private var ring: some View {
        Ellipse().strokeBorder(Theme.muted.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            .frame(width: fullscreen ? 340 : 280, height: fullscreen ? 110 : 90)
            .offset(y: fullscreen ? 70 : 50)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var expand: some View {
        Button(action: toggle) {
            Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.ink).frame(width: 44, height: 44).background(Theme.ground.opacity(0.85), in: Circle())
        }
        .accessibilityLabel("Fullscreen").padding(12)
    }

    private var collapse: some View {
        Button(action: toggle) {
            Image(systemName: "arrow.down.right.and.arrow.up.left").font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.ink).frame(width: 44, height: 44).background(Theme.ground.opacity(0.9), in: Circle())
        }
        .accessibilityLabel("Close fullscreen").padding(.top, 8).padding(.leading, 16)
    }

    private func place() {
        let d = SIMD3(cos(elevation) * sin(azimuth), sin(elevation), cos(elevation) * cos(azimuth)) * distance
        camera.look(at: .zero, from: d, relativeTo: nil)
    }
}

/// Paper "I": bottom sheet listing rooms; the plus places the object.
private struct AddToRoomSheet: View {
    let objectName: String
    let pick: (Project) -> Void
    @Environment(ProjectStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var chosen: UUID?

    var body: some View {
        let rooms = store.projects.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Add \(objectName.lowercased()) to…").font(.forma(20, bold: true)).foregroundStyle(Theme.ink)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.ink)
                        .frame(width: 40, height: 40).background(Theme.tiles[0], in: Circle())
                }
                .accessibilityLabel("Close")
            }
            SearchField(text: $query, prompt: "Search \(store.projects.count) rooms")
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(rooms) { project in
                        SheetRoomRow(project: project, highlighted: chosen == project.id) {
                            chosen = project.id
                            pick(project)
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
        .padding(.horizontal, 24).padding(.top, 28)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(32)
        .presentationBackground(Theme.ground)
    }
}

private struct SheetRoomRow: View {
    @Environment(ProjectStore.self) private var store
    let project: Project
    let highlighted: Bool
    let add: () -> Void
    @State private var summary = ""

    var body: some View {
        HStack(spacing: 12) {
            RoomGlyph().frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name).font(.forma(14, bold: true)).foregroundStyle(Theme.ink)
                Text(summary).font(.forma(11)).foregroundStyle(Theme.muted)
            }
            Spacer()
            Image(systemName: "plus").font(.system(size: 14, weight: .semibold))
                .foregroundStyle(highlighted ? Theme.onSage : Theme.ink)
                .frame(width: 36, height: 36)
                .background(highlighted ? Theme.sage : .clear, in: Circle())
                .overlay { if !highlighted { Circle().strokeBorder(Theme.ink.opacity(0.7), lineWidth: 1) } }
        }
        .padding(10)
        .background(highlighted ? Theme.tiles[0] : .clear, in: RoundedRectangle(cornerRadius: 18))
        .contentShape(Rectangle())
        .onTapGesture(perform: add)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Add to \(project.name)")
        .task(id: project) { summary = roomSummary(project, store: store) ?? "" }
    }
}
