import SwiftUI

@main
struct RoomVibeApp: App {
    @State private var store = ProjectStore()

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environment(store)
        }
    }
}
