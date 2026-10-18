import SwiftUI

struct HomeView: View {
    @Environment(ProjectStore.self) private var store
    @Environment(VibeLibrary.self) private var library
    @Environment(\.cloudSync) private var sync
    @State private var router = Router()
    @State private var tab = HomeTab.rooms
    @State private var openedDemo = false
    @State private var scanningRoom = false
    @State private var scanningObject = false
    @State private var error: String?
    @State private var renaming: Rename?
    @State private var newName = ""
    @State private var roomQuery = ""
    @State private var objectQuery = ""

    private enum Rename { case room(Project), object(ScannedObject) }
    @Namespace private var zoom   // Home thumbnails zoom into their detail screens

    var body: some View {
        NavigationStack(path: $router.path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    switch tab {
                    case .rooms: roomsSection
                    case .objects: objectsSection
                    case .vibes: VibesTab().environment(router)
                    }
                    if !Capabilities.canScanRoom {
                        Text("This device has no LiDAR. Scanning is off; use the demo data to explore.")
                            .font(.forma(11)).foregroundStyle(Theme.muted)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 24)
                .padding(.bottom, 24)
                // New rooms / scans slide in; counts roll (SectionHeader).
                .animation(.spring(duration: 0.4, bounce: 0.15), value: store.projects.map(\.id))
                .animation(.spring(duration: 0.4, bounce: 0.15), value: store.objects.map(\.id))
            }
            .scrollIndicators(.hidden)
            .background(Theme.ground.ignoresSafeArea())
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    header.padding(.horizontal, 24).padding(.top, 12)
                    HomeTabBar(selection: $tab, counts: [store.projects.count, store.objects.count, library.vibes.count])
                }
                .background(Theme.ground)
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Route.self) { route in
                Group { switch route {
                case .room(let id, let added):
                    RoomDetailView(projectID: id, added: added).navigationTransition(.zoom(sourceID: id, in: zoom))
                case .object(let id, let picks):
                    ObjectDetailView(objectID: id, picks: picks).navigationTransition(.zoom(sourceID: id, in: zoom))
                case .designer(let id, let opensCatalog): DesignerView(projectID: id, opensCatalog: opensCatalog)
                case .newVibe(let applyTo): CreateVibeView(applyTo: applyTo)
                case .vibe(let id): VibeDetailView(vibeID: id)
                } }
                .environment(router)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                HStack(spacing: 12) {
                    Button { scanningRoom = true } label: {
                        HStack(spacing: 10) { Text("Scan Room"); Image(systemName: "cube.transparent") }
                    }
                    .buttonStyle(PillButtonStyle())
                    .disabled(!Capabilities.canScanRoom)
                    Button { scanningObject = true } label: {
                        HStack(spacing: 10) { Text("Scan Object"); Image(systemName: "camera.viewfinder") }
                    }
                        .buttonStyle(PillButtonStyle(filled: false))
                        .disabled(!Capabilities.canScanObject)
                }
                .padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 8)
                .background(Theme.ground.opacity(0.7))
                .background(.ultraThinMaterial)
                .overlay(alignment: .top) { Theme.hairline.frame(height: 1) }
            }
            .fullScreenCover(isPresented: $scanningRoom) {
                RoomScanView { project in router.path.append(.room(project.id)) }
            }
            .fullScreenCover(isPresented: $scanningObject) {
                // Fresh scan: open it with "Add to a room" ready, the next thing you'd do.
                ObjectScanView { object in router.path.append(.object(object.id, picks: !store.projects.isEmpty)) }
            }
            .task {
                // Shared team data: everyone gets the bundled UCLA dorm once (deleting it keeps it gone).
                if !UserDefaults.standard.bool(forKey: "seededUCLADorm"), !ProcessInfo.processInfo.arguments.contains("-demo") {
                    // A reinstall keeps the cloud user: pull its dorm first, or seeding adds a second one.
                    // Both paths below add the dorm only when no room has its name.
                    if let sync { await sync.waitForFirstPass(timeout: .seconds(8)) }
                    if !Task.isCancelled {   // Home went away mid-wait: decide on its next appearance
                        UserDefaults.standard.set(true, forKey: "seededUCLADorm")
                        if store.projects.isEmpty { try? store.loadDemoData() } else { try? store.addBundledDorm() }
                    }
                }
                // Launch with `-demo` (Scheme > Run > Arguments) to jump straight into the demo room.
                guard ProcessInfo.processInfo.arguments.contains("-demo"), !openedDemo else { return }
                openedDemo = true   // .task reruns whenever Home reappears; jump in only once
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-fresh") { store.projects.forEach(store.delete) }   // UI tests
                #endif
                if store.projects.isEmpty { try? store.loadDemoData() }
                let args = ProcessInfo.processInfo.arguments
                let named = args.firstIndex(of: "-room").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }   // `-room "UCLA dorm"`
                if let p = store.projects.first(where: { $0.name == named }) ?? store.projects.first { router.path = [.designer(p.id)] }
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
            HStack(spacing: 10) { Logo(size: 22); Wordmark(size: 24) }
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
            if store.projects.count > 5 { SearchField(text: $roomQuery, prompt: "Search \(store.projects.count) rooms").padding(.bottom, 8) }
            if store.projects.isEmpty {
                Text("No rooms yet. Scan one, or load the demo room.")
                    .font(.forma(12)).foregroundStyle(Theme.muted).padding(.vertical, 12)
            }
            ForEach(rooms) { project in
                Button { open(.room(project.id)) } label: {
                    RoomRow(project: project).matchedTransitionSource(id: project.id, in: zoom)
                }
                    .buttonStyle(.plain)
                    .transition(.opacity.combined(with: .move(edge: .top)))
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
            if store.objects.count > 6 { SearchField(text: $objectQuery, prompt: "Search \(store.objects.count) objects") }
            if store.objects.isEmpty {
                Text("Scan a real object to place it in your rooms.")
                    .font(.forma(12)).foregroundStyle(Theme.muted)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: 3), spacing: 16) {
                ForEach(Array(objects.enumerated()), id: \.element.id) { i, object in
                    Button { open(.object(object.id)) } label: {
                        ObjectTile(object: object, tint: Theme.tiles[i % Theme.tiles.count])
                            .matchedTransitionSource(id: object.id, in: zoom)
                    }
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                        .contextMenu {
                            Button("Rename", systemImage: "pencil") { startRename(.object(object), object.name) }
                            Button("Delete", systemImage: "trash", role: .destructive) { store.delete(object) }
                        }
                }
            }
        }
    }

    /// Push with a slow, soft zoom instead of the default quick one.
    private func open(_ route: Route) {
        withTransaction(Transaction(animation: .smooth(duration: 0.75))) { router.path.append(route) }
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
            RoomThumb(projectID: project.id).frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 16))
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
            summary = roomSummary(project, store: store) ?? ""
        }
    }
}

private struct ObjectTile: View {
    let object: ScannedObject
    let tint: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ObjectThumb(object: object)
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
