import SwiftUI

enum HomeTab: CaseIterable {
    case rooms, objects, vibes
    var title: String {
        switch self { case .rooms: "Rooms"; case .objects: "Objects"; case .vibes: "Vibes" }
    }
}

/// Sticky Rooms / Objects / Vibes switcher (Paper "v2 · A"): selected tab is bold ink with a sage underline.
struct HomeTabBar: View {
    @Binding var selection: HomeTab
    let counts: [Int]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(HomeTab.allCases.enumerated()), id: \.element) { i, tab in
                let on = tab == selection
                Button { selection = tab } label: {
                    HStack(spacing: 6) {
                        Text(tab.title).font(.forma(13, bold: on))
                        Text(String(format: "%02d", counts[i])).font(.forma(11))
                    }
                    .foregroundStyle(on ? Theme.ink : Theme.muted)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .overlay(alignment: .bottom) { (on ? Theme.sage : .clear).frame(height: 2) }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
                .accessibilityIdentifier("tab\(tab.title)")
            }
        }
        .padding(.horizontal, 24).padding(.top, 8)
        .overlay(alignment: .bottom) { Theme.hairline.frame(height: 1) }
    }
}

/// Vibes tab (Paper "v2 · A3"): dashed "+ Vibe" card first, then two-column vibe cards.
struct VibesTab: View {
    @Environment(VibeLibrary.self) private var library
    @Environment(ProjectStore.self) private var store
    @Environment(Router.self) private var router

    var body: some View {
        let columns = [GridItem(.flexible(), spacing: 12, alignment: .top), GridItem(.flexible(), spacing: 12, alignment: .top)]
        LazyVGrid(columns: columns, spacing: 16) {
            Button { router.path.append(.newVibe()) } label: {
                VStack(spacing: 10) {
                    Image(systemName: "plus").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.onSage)
                        .frame(width: 40, height: 40).background(Theme.sage, in: Circle())
                    Text("+ Vibe").font(.forma(13, bold: true)).foregroundStyle(Theme.ink)
                }
                .frame(maxWidth: .infinity).frame(height: 132)
                .background(Theme.sand, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Theme.sage, style: StrokeStyle(lineWidth: 1.5, dash: [4, 4])))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("newVibe")
            ForEach(library.vibes) { vibe in
                NavigationLink(value: Route.vibe(vibe.id)) { VibeCard(vibe: vibe, rooms: rooms(for: vibe)) }
                    .buttonStyle(.plain)
            }
        }
    }

    private func rooms(for vibe: SavedVibe) -> [String] {
        store.projects.filter { $0.vibeID == vibe.id }.map(\.name)
    }
}

private struct VibeCard: View {
    let vibe: SavedVibe
    let rooms: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VibeTile(vibe: vibe, square: false).frame(height: 132).frame(maxWidth: .infinity)
            Text(vibe.name).font(.system(size: 18, weight: .semibold, design: .serif)).foregroundStyle(Theme.ink).lineLimit(2)
            Text(vibe.styles.prefix(2).joined(separator: " · ")).font(.forma(11)).foregroundStyle(Theme.muted).lineLimit(1)
            SwatchDots(colors: vibe.colors, size: 12)
            if rooms.isEmpty {
                Text("Not in a room yet").font(.forma(10)).foregroundStyle(Theme.muted)
            } else {
                FlowLayout(spacing: 4) {
                    ForEach(rooms, id: \.self) {
                        Text($0).font(.forma(10)).foregroundStyle(Theme.wood)
                            .padding(.horizontal, 8).padding(.vertical, 3).background(Theme.sand, in: Capsule())
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}
