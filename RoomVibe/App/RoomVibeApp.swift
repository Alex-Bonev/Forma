import SwiftUI

@main
struct RoomVibeApp: App {
    @State private var store: ProjectStore
    /// nil without a cloud config, and in UI-test runs: the library then stays on this device.
    @State private var sync: CloudSync?
    @Environment(\.scenePhase) private var scenePhase
    @State private var vibeLibrary: VibeLibrary
    @State private var connectivity = Connectivity()
    @AppStorage("forma.seenStart") private var seenStart = false
    @State private var splash = true
    /// UI tests and `-demo` skip the intro and open the demo room directly.
    private let skipIntro = ProcessInfo.processInfo.arguments.contains("-demo")

    init() {
        Theme.registerFonts()
        // Built eagerly: State(initialValue:) takes a value. An App's init runs once per launch, so this loads the
        // library once.
        let store = ProjectStore(), vibes = VibeLibrary()
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-seedVibe") { vibes.seedForUITests() }
        #endif
        _store = State(initialValue: store)
        _vibeLibrary = State(initialValue: vibes)
        // Made here rather than in a `.task`: HomeView's first-launch seeding must already see it, to wait for its
        // first pass.
        _sync = State(initialValue: CloudSync.isUITestRun ? nil : CloudSync(store: store, vibes: vibes))
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                HomeView()
                    .environment(store)
                    .environment(vibeLibrary)
                    .environment(connectivity)
                    .environment(\.cloudSync, sync)
                if !skipIntro && !seenStart && !splash {
                    StartView { withAnimation(.easeOut(duration: 0.3)) { seenStart = true } }
                        .transition(.opacity)
                }
                if !skipIntro && splash {
                    LoadingView(status: connectivity.online ? nil : "No connection · retrying")
                        .transition(.opacity)
                }
            }
            .preferredColorScheme(.light)   // the forma palette is light-only; dark system text in sheets/menus was unreadable on it
            .task {
                // Wake a cold Vercel function now, so the first "Make it real" doesn't pay for the cold start.
                _ = try? await APIClient.shared.health()
            }
            .task {
                // A pass now pulls rooms, objects and vibes from other sessions; later passes follow local changes.
                // Called directly, not scheduled: a save during the debounce would push the first pass back 2 s, and
                // first-launch seeding waits on it.
                await sync?.sync()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { sync?.schedule(after: .zero) }   // back from the background: catch up
            }
            .task {
                // One full loop of the mark, then hand over to Start (first launch) or Home.
                guard splash, !skipIntro else { return }
                try? await Task.sleep(for: .seconds(1.2))
                withAnimation(.easeOut(duration: 0.35)) { splash = false }
            }
        }
    }
}

extension EnvironmentValues {
    /// The app's CloudSync; nil without a cloud config and in UI-test runs.
    @Entry var cloudSync: CloudSync? = nil
}
