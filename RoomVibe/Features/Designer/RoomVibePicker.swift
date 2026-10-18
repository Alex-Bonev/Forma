import SwiftUI

/// Fullscreen room: the vibe pill and its dropdown (Paper E5). With no saved vibes the pill goes straight to making one.
/// Applying stores `Project.vibeID`; Shop a vibe then starts from it. The faithful Make it real render ignores it.
struct RoomVibeControl<Leading: View>: View {
    @Environment(ProjectStore.self) private var store
    @Environment(VibeLibrary.self) private var library
    @Environment(Router.self) private var router
    let projectID: UUID
    var compact = false
    var fill = Theme.sand
    var ink = Theme.ink
    /// The dropdown opens above the pill (for a pill near the bottom of the screen).
    var opensUp = false
    /// The pill stretches to the width it is offered (half of a two-button row).
    var fillsWidth = false
    /// Owned by the screen, so a tap anywhere else on it can close the dropdown.
    @Binding var showMenu: Bool
    @ViewBuilder var leading: Leading

    private var project: Project? { store.projects.first { $0.id == projectID } }
    private var applied: SavedVibe? { project?.vibeID.flatMap(library.vibe) }

    var body: some View {
        HStack(spacing: 8) {
            leading
            pill
        }
        // A huge clear scrim behind the pill: tap outside only closes, the layout never moves.
        .background {
            if showMenu {
                Color.black.opacity(0.001).frame(width: 4000, height: 4000)
                    .onTapGesture { showMenu = false }
            }
        }
        .overlay(alignment: opensUp ? .bottomLeading : .topLeading) {
            if showMenu {
                VibeDropdownMenu(
                    header: "VIBE FOR \((project?.name ?? "ROOM").uppercased())",
                    selected: applied?.id,
                    clearTitle: applied != nil ? "Remove vibe from room" : nil,
                    onSelect: { apply($0); showMenu = false },
                    onClear: { apply(nil); showMenu = false },
                    onNew: { showMenu = false; newVibe() }
                )
                .frame(width: 280)
                .fixedSize(horizontal: false, vertical: true)   // the overlay proposes the pill's height; without this the list collapses
                .offset(y: opensUp ? -52 : 52)
                .transition(.scale(scale: 0.96, anchor: opensUp ? .bottomLeading : .topLeading).combined(with: .opacity))
            }
        }
        .zIndex(showMenu ? 1 : 0)
        .animation(.spring(duration: 0.28, bounce: 0.12), value: showMenu)
        .onChange(of: compact) { showMenu = false }
    }

    private var pill: some View {
        Button {
            if library.vibes.isEmpty { newVibe() } else { showMenu.toggle() }
        } label: {
            HStack(spacing: 8) {
                if let applied {
                    SwatchDots(colors: Array(applied.colors.prefix(3)), size: 12)
                    if !compact {
                        Text(applied.name).font(.forma(12, bold: true)).foregroundStyle(ink).lineLimit(1)
                        chevron
                    }
                } else {
                    Image(systemName: "swatchpalette").font(.system(size: compact ? 18 : 15, weight: .semibold))
                        .foregroundStyle(Theme.sageDeep)
                    if !compact {
                        Text("Vibe").font(.forma(12, bold: true)).foregroundStyle(ink)
                        if !library.vibes.isEmpty {
                            chevron
                        }
                    }
                }
            }
            .padding(.horizontal, compact ? 0 : 16)
            .frame(width: compact ? 44 : nil, height: 44)
            .frame(maxWidth: fillsWidth ? .infinity : nil)
            .background(fill, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.sage, lineWidth: 1.5))
        }
        .accessibilityLabel(applied.map { "Vibe: \($0.name)" } ?? "Add a vibe")
        .accessibilityIdentifier("roomVibe")
    }

    private var chevron: some View {
        Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold)).foregroundStyle(ink)
            .rotationEffect(.degrees(showMenu ? 180 : 0))
    }

    private func apply(_ id: UUID?) {
        guard var p = project else { return }
        p.vibeID = id
        store.update(p)
    }

    private func newVibe() { router.path.append(.newVibe(applyTo: projectID)) }
}
