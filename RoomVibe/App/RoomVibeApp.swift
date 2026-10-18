import SwiftUI

@main
struct RoomVibeApp: App {
    @State private var store = ProjectStore()
    @State private var connectivity = Connectivity()
    @AppStorage("forma.seenStart") private var seenStart = false
    @State private var splash = true
    /// UI tests and `-demo` skip the intro and open the demo room directly.
    private let skipIntro = ProcessInfo.processInfo.arguments.contains("-demo")

    init() { Theme.registerFonts() }

    var body: some Scene {
        WindowGroup {
            ZStack {
                HomeView()
                    .environment(store)
                    .environment(connectivity)
                if !skipIntro && !seenStart && !splash {
                    StartView { withAnimation(.easeOut(duration: 0.3)) { seenStart = true } }
                        .transition(.opacity)
                }
                if !skipIntro && splash {
                    LoadingView(status: connectivity.online ? nil : "No connection · retrying")
                        .transition(.opacity)
                }
            }
            .task {
                // Wake a cold Vercel function now, so the first "Make it real" doesn't pay for the cold start.
                _ = try? await APIClient.shared.health()
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
