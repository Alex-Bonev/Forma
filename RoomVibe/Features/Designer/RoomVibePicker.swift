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
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                leading
                pill
            }
            .overlay(alignment: .bottomLeading) {
                // Floats above the pill without widening the row it sits in.
                if opensUp && showMenu {
                    menu.fixedSize().offset(y: -52)
                        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottomLeading)))
                }
            }
            if !opensUp && showMenu { menu.transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topLeading))) }
        }
        .animation(.spring(duration: 0.25, bounce: 0), value: showMenu)
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
                        Image(systemName: showMenu != opensUp ? "chevron.up" : "chevron.down")
                            .font(.system(size: 11, weight: .bold)).foregroundStyle(ink)
                    }
                } else {
                    Image(systemName: "swatchpalette").font(.system(size: compact ? 18 : 15, weight: .semibold))
                        .foregroundStyle(Theme.sageDeep)
                    if !compact {
                        Text("Vibe").font(.forma(12, bold: true)).foregroundStyle(ink)
                        if !library.vibes.isEmpty {
                            Image(systemName: showMenu != opensUp ? "chevron.up" : "chevron.down")
                                .font(.system(size: 11, weight: .bold)).foregroundStyle(ink)
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

    private var menu: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(library.vibes) { vibe in
                Button { apply(vibe.id); showMenu = false } label: {
                    VibeRow(vibe: vibe, tile: 36).overlay(alignment: .trailing) {
                        if vibe.id == applied?.id { Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.muted) }
                    }
                    .padding(8)
                    .background(vibe.id == applied?.id ? Theme.sand : .clear, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("vibeOption")
            }
            Theme.hairline.frame(height: 1).padding(.vertical, 4)
            Button { showMenu = false; newVibe() } label: {
                menuRow("plus", "New vibe", bold: true)
            }
            .accessibilityIdentifier("newRoomVibe")
            if applied != nil {
                Button { apply(nil); showMenu = false } label: { menuRow("xmark", "Remove", bold: false) }
            }
        }
        .buttonStyle(.plain)
        .padding(10)
        .frame(width: 280)
        .background(Theme.ground, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 16, y: 6)
    }

    private func menuRow(_ icon: String, _ title: String, bold: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 14, weight: .semibold)).frame(width: 36, height: 36)
            Text(title).font(.forma(12, bold: bold))
            Spacer(minLength: 0)
        }
        .foregroundStyle(bold ? Theme.ink : Theme.muted).padding(.horizontal, 8).contentShape(Rectangle())
    }

    private func apply(_ id: UUID?) {
        guard var p = project else { return }
        p.vibeID = id
        store.update(p)
    }

    private func newVibe() { router.path.append(.newVibe(applyTo: projectID)) }
}

/// Tile, name and tag line for one vibe.
private struct VibeRow: View {
    let vibe: SavedVibe
    let tile: CGFloat

    var body: some View {
        HStack(spacing: 12) {
            VibeTile(vibe: vibe, corner: 10).frame(width: tile, height: tile)
            VStack(alignment: .leading, spacing: 2) {
                Text(vibe.name).font(.forma(13, bold: true)).foregroundStyle(Theme.ink).lineLimit(1)
                Text((vibe.mood.prefix(1) + vibe.materials.prefix(1)).joined(separator: " · "))
                    .font(.forma(10)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }
}
