import SwiftUI

/// Fullscreen room: the vibe pill next to "Make it real", its dropdown (Paper E5) and the add-a-vibe sheet (Paper E4).
/// Applying only stores `Project.vibeID`; it never touches the render restyle.
struct RoomVibeControl<Leading: View>: View {
    @Environment(ProjectStore.self) private var store
    @Environment(VibeLibrary.self) private var library
    @Environment(Router.self) private var router
    let projectID: UUID
    var compact = false
    var fill = Theme.sand
    var ink = Theme.ink
    @ViewBuilder var leading: Leading
    @State private var showMenu = false
    @State private var showSheet = false

    private var project: Project? { store.projects.first { $0.id == projectID } }
    private var applied: SavedVibe? { project?.vibeID.flatMap(library.vibe) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                leading
                pill
            }
            if showMenu { menu.transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topLeading))) }
        }
        .animation(.spring(duration: 0.25, bounce: 0), value: showMenu)
        .onChange(of: compact) { showMenu = false }
        .sheet(isPresented: $showSheet) {
            AddVibeSheet(projectID: projectID) { showSheet = false; newVibe() }
                .presentationDetents([.medium, .large])
                .presentationBackground(Theme.ground)
        }
    }

    private var pill: some View {
        Button {
            if applied == nil { showSheet = true } else { showMenu.toggle() }
        } label: {
            HStack(spacing: 8) {
                if let applied {
                    SwatchDots(colors: Array(applied.colors.prefix(3)), size: 12)
                    if !compact {
                        Text(applied.name).font(.forma(12, bold: true)).foregroundStyle(ink).lineLimit(1)
                        Image(systemName: showMenu ? "chevron.up" : "chevron.down")
                            .font(.system(size: 11, weight: .bold)).foregroundStyle(ink)
                    }
                } else {
                    Image(systemName: "swatchpalette").font(.system(size: compact ? 18 : 15, weight: .semibold))
                        .foregroundStyle(Theme.sageDeep)
                    if !compact { Text("Vibe").font(.forma(12, bold: true)).foregroundStyle(ink) }
                }
            }
            .padding(.horizontal, compact ? 0 : 16)
            .frame(width: compact ? 44 : nil, height: 44)
            .background(fill, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.sage, lineWidth: 1.5))
        }
        .accessibilityLabel(applied.map { "Vibe: \($0.name)" } ?? "Add a vibe")
        .accessibilityIdentifier("roomVibe")
    }

    private var menu: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("VIBE FOR \((project?.name ?? "").uppercased())").font(.forma(10)).foregroundStyle(Theme.muted)
                .lineLimit(1).padding(.horizontal, 8).padding(.bottom, 4)
            ForEach(library.vibes) { vibe in
                Button { apply(vibe.id); showMenu = false } label: {
                    VibeRow(vibe: vibe, tile: 36).overlay(alignment: .trailing) {
                        if vibe.id == applied?.id { Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.muted) }
                    }
                    .padding(8)
                    .background(vibe.id == applied?.id ? Theme.sand : .clear, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            Theme.hairline.frame(height: 1).padding(.vertical, 4)
            Button { showMenu = false; newVibe() } label: {
                menuRow("plus", "New vibe from photos", bold: true)
            }
            Button { apply(nil); showMenu = false } label: {
                menuRow("xmark", "Remove vibe from room", bold: false)
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

/// "Add a vibe" sheet (Paper E4): pick a saved vibe, Apply, or start a new one from photos.
private struct AddVibeSheet: View {
    @Environment(ProjectStore.self) private var store
    @Environment(VibeLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss
    let projectID: UUID
    let onNew: () -> Void
    @State private var picked: UUID?

    private var chosen: SavedVibe? { picked.flatMap(library.vibe) ?? library.vibes.first }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Add a vibe").font(.system(size: 28, weight: .bold, design: .serif)).foregroundStyle(Theme.ink)
                    .accessibilityAddTraits(.isHeader)
                Text("to \(store.projects.first { $0.id == projectID }?.name ?? "this room")")
                    .font(.forma(12)).foregroundStyle(Theme.muted)
                ForEach(library.vibes) { vibe in
                    let on = vibe.id == chosen?.id
                    Button { picked = vibe.id } label: {
                        HStack {
                            VibeRow(vibe: vibe, tile: 52)
                            Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 24)).foregroundStyle(on ? Theme.sage : Theme.hairline)
                        }
                        .padding(12)
                        .background(on ? Theme.sand : .clear, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(on ? Theme.sage : .clear, lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
                if library.vibes.isEmpty {
                    Text("No saved vibes yet.").font(.forma(12)).foregroundStyle(Theme.muted)
                }
                if let chosen {
                    Button("Apply \(chosen.name)") {
                        if var p = store.projects.first(where: { $0.id == projectID }) {
                            p.vibeID = chosen.id
                            store.update(p)
                        }
                        dismiss()
                    }
                    .buttonStyle(PillButtonStyle()).padding(.top, 8)
                    .accessibilityIdentifier("applyVibe")
                }
                Button(action: onNew) { Label("New vibe from photos", systemImage: "plus") }
                    .buttonStyle(PillButtonStyle(filled: false))
            }
            .padding(24)
        }
    }
}

/// Tile, serif name and tag line for one vibe.
private struct VibeRow: View {
    let vibe: SavedVibe
    let tile: CGFloat

    var body: some View {
        HStack(spacing: 12) {
            VibeTile(vibe: vibe, corner: 10).frame(width: tile, height: tile)
            VStack(alignment: .leading, spacing: 2) {
                Text(vibe.name).font(.system(size: 17, weight: .bold, design: .serif)).foregroundStyle(Theme.ink).lineLimit(1)
                Text((vibe.mood.prefix(1) + vibe.materials.prefix(1)).joined(separator: " · "))
                    .font(.forma(10)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }
}
