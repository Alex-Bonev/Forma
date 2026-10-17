import SwiftUI

struct HomeView: View {
    @Environment(ProjectStore.self) private var store
    @State private var path: [UUID] = []
    @State private var scanningRoom = false
    @State private var scanningObject = false
    @State private var error: String?

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section("Rooms") {
                    if store.projects.isEmpty {
                        Text("No rooms yet. Scan one, or load the demo room.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(store.projects) { project in
                        NavigationLink(value: project.id) {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(project.name).font(.headline)
                                    Text(project.createdAt, style: .date)
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: "cube.transparent").foregroundStyle(.tint)
                            }
                        }
                        .swipeActions { Button("Delete", role: .destructive) { store.delete(project) } }
                    }
                }

                Section("Object Library") {
                    if store.objects.isEmpty {
                        Text("Scan a real object to place it in your rooms.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(store.objects) { object in
                        Label(object.name, systemImage: object.modelFile == nil ? "chair" : "chair.fill")
                            .swipeActions { Button("Delete", role: .destructive) { store.delete(object) } }
                    }
                }

                if !Capabilities.canScanRoom {
                    Section {
                        Label("This device has no LiDAR. Scanning is off; use the demo data to explore.",
                              systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("RoomVibe")
            .navigationDestination(for: UUID.self) { DesignerView(projectID: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Load Demo Data", systemImage: "shippingbox") {
                            do { try store.loadDemoData() } catch { self.error = error.localizedDescription }
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 12) {
                    Button { scanningRoom = true } label: {
                        Label("Scan Room", systemImage: "viewfinder").frame(maxWidth: .infinity)
                    }
                    .disabled(!Capabilities.canScanRoom)
                    Button { scanningObject = true } label: {
                        Label("Scan Object", systemImage: "camera.metering.center.weighted").frame(maxWidth: .infinity)
                    }
                    .disabled(!Capabilities.canScanObject)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding()
                .background(.bar)
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
            .alert("Something went wrong", isPresented: .constant(error != nil)) {
                Button("OK") { error = nil }
            } message: { Text(error ?? "") }
        }
    }
}
