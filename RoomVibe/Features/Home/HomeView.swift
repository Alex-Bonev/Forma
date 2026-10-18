import SwiftUI

struct HomeView: View {
    @Environment(ProjectStore.self) private var store
    @State private var path: [UUID] = []
    @State private var scanningRoom = false
    @State private var scanningObject = false
    @State private var error: String?
    @State private var renaming: Rename?
    @State private var newName = ""
    @State private var roomQuery = ""
    @State private var objectQuery = ""

    private enum Rename { case room(Project), object(ScannedObject) }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    roomsSection
                    objectsSection
                    if !Capabilities.canScanRoom {
                        Text("This device has no LiDAR. Scanning is off; use the demo data to explore.")
                            .font(.forma(11)).foregroundStyle(Theme.muted)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            .background(Theme.ground.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: UUID.self) { DesignerView(projectID: $0) }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                HStack(spacing: 12) {
                    Button { scanningRoom = true } label: {
                        HStack(spacing: 10) { Text("Scan Room"); Image(systemName: "arrow.right") }
                    }
                    .buttonStyle(PillButtonStyle())
                    .disabled(!Capabilities.canScanRoom)
                    Button("Scan Object") { scanningObject = true }
                        .buttonStyle(PillButtonStyle(filled: false))
                        .disabled(!Capabilities.canScanObject)
                }
                .padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 8)
                .background(Theme.ground.opacity(0.7))
                .background(.ultraThinMaterial)
                .overlay(alignment: .top) { Theme.hairline.frame(height: 1) }
            }
            .fullScreenCover(isPresented: $scanningRoom) {
                RoomScanView { project in path.append(project.id) }
            }
            .fullScreenCover(isPresented: $scanningObject) {
                ObjectScanView()
            }
            .task {
                // Launch with `-demo` (Scheme > Run > Arguments) to jump straight into the demo room.
                guard ProcessInfo.processInfo.arguments.contains("-demo") else { return }
                if store.projects.isEmpty { try? store.loadDemoData() }
                if let first = store.projects.first { path = [first.id] }
            }
            .alert("Rename", isPresented: .constant(renaming != nil)) {
                TextField("Name", text: $newName)
                Button("Save") { commitRename() }
                Button("Cancel", role: .cancel) { renaming = nil }
            }
            .alert("Something went wrong", isPresented: .constant(error != nil)) {
                Button("OK") { error = nil }
            } message: { Text(error ?? "") }
        }
    }

    private var header: some View {
        HStack {
            Text("forma").font(.forma(24, bold: true, relativeTo: .largeTitle)).tracking(-0.7)
                .foregroundStyle(Theme.ink)
            Spacer()
            Menu {
                Button("Load Demo Data", systemImage: "shippingbox") {
                    do { try store.loadDemoData() } catch { self.error = error.localizedDescription }
                }
            } label: {
                Image(systemName: "ellipsis").foregroundStyle(Theme.ink).frame(width: 44, height: 44)
            }
            .accessibilityLabel("More")
        }
    }

    private var roomsSection: some View {
        let rooms = store.projects.filter { matches($0.name, roomQuery) }
        return VStack(alignment: .leading, spacing: 4) {
            SectionHeader(title: "Rooms", count: store.projects.count).padding(.bottom, 4)
            if store.projects.count > 5 { SearchField(text: $roomQuery, prompt: "Search \(store.projects.count) rooms") }
            if store.projects.isEmpty {
                Text("No rooms yet. Scan one, or load the demo room.")
                    .font(.forma(12)).foregroundStyle(Theme.muted).padding(.vertical, 12)
            }
            ForEach(rooms) { project in
                NavigationLink(value: project.id) { RoomRow(project: project) }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Rename", systemImage: "pencil") { startRename(.room(project), project.name) }
                        Button("Delete", systemImage: "trash", role: .destructive) { store.delete(project) }
                    }
            }
        }
    }

    private var objectsSection: some View {
        let objects = store.objects.filter { matches($0.name, objectQuery) }
        return VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Object library", count: store.objects.count)
            if store.objects.count > 6 { SearchField(text: $objectQuery, prompt: "Search \(store.objects.count) objects") }
            if store.objects.isEmpty {
                Text("Scan a real object to place it in your rooms.")
                    .font(.forma(12)).foregroundStyle(Theme.muted)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: 3), spacing: 16) {
                ForEach(Array(objects.enumerated()), id: \.element.id) { i, object in
                    ObjectTile(object: object, tint: Theme.tiles[i % Theme.tiles.count])
                        .contentShape(Rectangle())
                        .contextMenu {
                            Button("Rename", systemImage: "pencil") { startRename(.object(object), object.name) }
                            Button("Delete", systemImage: "trash", role: .destructive) { store.delete(object) }
                        }
                }
            }
        }
    }

    private func matches(_ name: String, _ query: String) -> Bool {
        query.isEmpty || name.localizedCaseInsensitiveContains(query)
    }

    private func startRename(_ target: Rename, _ current: String) {
        newName = current
        renaming = target
    }

    private func commitRename() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { renaming = nil }
        guard !name.isEmpty else { return }
        switch renaming {
        case .room(var p): p.name = name; store.update(p)
        case .object(let o): store.rename(o, to: name)
        case nil: break
        }
    }
}

private struct RoomRow: View {
    @Environment(ProjectStore.self) private var store
    let project: Project
    @State private var summary = ""

    var body: some View {
        HStack(spacing: 16) {
            RoomGlyph().frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 16))
            VStack(alignment: .leading, spacing: 4) {
                Text(project.name).font(.forma(15, bold: true)).foregroundStyle(Theme.ink)
                Text(summary).font(.forma(12)).foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.wood)
        }
        .padding(.vertical, 12)
        .overlay(alignment: .top) { Theme.hairline.frame(height: 1) }
        .contentShape(Rectangle())
        .task(id: project) {
            guard let room = store.room(for: project) else { return }
            let (lo, hi) = RoomBuilder.bounds(room)
            let n = project.placements.count + room.objects.count - (project.hiddenRoomObjects?.count ?? 0)
            summary = String(format: "%.1f × %.1f m · %d item%@", hi.x - lo.x, hi.z - lo.z, n, n == 1 ? "" : "s")
        }
    }
}

/// Stylised room thumbnail from the design: back wall, floor, one piece of furniture.
private struct RoomGlyph: View {
    var body: some View {
        Canvas { ctx, size in
            let u = size.width / 64
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.hairline))
            ctx.fill(Path(CGRect(x: 14 * u, y: 14 * u, width: 36 * u, height: 28 * u)), with: .color(Color(hex: 0xBDB1A1)))
            ctx.fill(Path(CGRect(x: 0, y: 42 * u, width: size.width, height: 22 * u)), with: .color(Color(hex: 0xD8CCBB)))
            ctx.fill(Path(roundedRect: CGRect(x: 18 * u, y: 34 * u, width: 28 * u, height: 12 * u), cornerRadius: 2 * u),
                     with: .color(Theme.wood))
        }
        .accessibilityHidden(true)
    }
}

private struct ObjectTile: View {
    let object: ScannedObject
    let tint: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "chair.lounge.fill")
                .font(.system(size: 30)).foregroundStyle(Theme.wood)
                .frame(maxWidth: .infinity).frame(height: 96)
                .background(tint, in: RoundedRectangle(cornerRadius: 20))
            Text(object.name).font(.forma(12, bold: true)).foregroundStyle(Theme.ink).lineLimit(1)
            Text(dims).font(.forma(11)).foregroundStyle(Theme.muted).lineLimit(1).minimumScaleFactor(0.8)
        }
    }

    /// Width × depth × height in cm.
    private var dims: String {
        let b = object.boundingBox * 100
        return String(format: "%.0f × %.0f × %.0f cm", b.x, b.z, b.y)
    }
}

private struct SearchField: View {
    @Binding var text: String
    let prompt: String
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted)
            TextField("", text: $text, prompt: Text(prompt).foregroundStyle(Theme.muted))
                .font(.forma(14)).foregroundStyle(Theme.ink).autocorrectionDisabled()
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.ink) }
                    .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 16).frame(height: 44)
        .background(Theme.hairline, in: Capsule())
        .padding(.bottom, 8)
    }
}
