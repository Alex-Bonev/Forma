import SwiftUI

@main
struct RoomVibeApp: App {
    @State private var store = ProjectStore()

    init() { Theme.registerFonts() }

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environment(store)
                .tint(Theme.sage)
        }
    }
}
