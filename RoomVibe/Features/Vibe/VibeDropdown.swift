import SwiftUI

/// The vibe dropdown card; callers place it, set its width and own the open state.
/// Used by the fullscreen room's vibe pill and by the vibe header on Shop a vibe.
struct VibeDropdownMenu: View {
    @Environment(VibeLibrary.self) private var library
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Small caps line at the top, e.g. "VIBE FOR LIVING ROOM". Empty hides it.
    var header = ""
    /// The vibe shown with a check. nil = none selected.
    var selected: UUID?
    /// Show a last row that clears the choice ("Remove vibe from room" and similar).
    var clearTitle: String? = nil
    var newTitle = "New vibe from photos"
    let onSelect: (UUID) -> Void
    let onClear: () -> Void
    let onNew: () -> Void

    @State private var shown = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !header.isEmpty {
                Text(header).font(.forma(10)).tracking(1.2).foregroundStyle(Theme.muted)
                    .padding(.horizontal, 8).padding(.top, 4).padding(.bottom, 2)
            }
            if library.vibes.isEmpty {
                Text("No saved vibes yet.").font(.forma(12)).foregroundStyle(Theme.muted)
                    .padding(.horizontal, 8).padding(.vertical, 10)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(Array(library.vibes.enumerated()), id: \.element.id) { i, vibe in
                            let isSelected = vibe.id == selected
                            Button { onSelect(vibe.id) } label: {
                                VibeRow(vibe: vibe, tile: 36).overlay(alignment: .trailing) {
                                    if isSelected {
                                        Image(systemName: "checkmark").font(.system(size: 12, weight: .bold))
                                            .foregroundStyle(Theme.sageDeep)
                                            .scaleEffect(shown ? 1 : 0.3)
                                            .animation(.spring(duration: 0.35, bounce: 0.4).delay(0.1), value: shown)
                                    }
                                }
                                .padding(.horizontal, 8).frame(minHeight: 44).contentShape(Rectangle())
                                .background(isSelected ? Theme.sand : .clear, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                            .buttonStyle(PressScaleStyle())
                            .accessibilityIdentifier("vibeOption-\(vibe.name)")
                            .accessibilityAddTraits(isSelected ? .isSelected : [])
                            .opacity(shown || reduceMotion ? 1 : 0)
                            .offset(y: shown || reduceMotion ? 0 : 6)
                            .animation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.1).delay(Double(i) * 0.025), value: shown)
                        }
                    }
                }
                .frame(maxHeight: 280)
                .scrollBounceBehavior(.basedOnSize)
            }
            if !newTitle.isEmpty || clearTitle != nil { Theme.hairline.frame(height: 1).padding(.vertical, 4) }
            if !newTitle.isEmpty {
            Button(action: onNew) {
                actionRow(title: newTitle, bold: true) {
                    Image(systemName: "plus").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.ink)
                        .frame(width: 36, height: 36)
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Theme.muted.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                }
            }
            .buttonStyle(PressScaleStyle())
            .accessibilityIdentifier("vibeNew")
            }
            if let clearTitle {
                Button(action: onClear) {
                    actionRow(title: clearTitle, bold: false) {
                        Image(systemName: "xmark").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.muted)
                            .frame(width: 36, height: 36)
                    }
                }
                .buttonStyle(PressScaleStyle())
                .accessibilityIdentifier("vibeClear")
            }
        }
        .padding(8)
        .background(Theme.ground, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.15), radius: 16, y: 6)
        .onAppear { shown = true }
    }

    private func actionRow<Icon: View>(title: String, bold: Bool, @ViewBuilder icon: () -> Icon) -> some View {
        HStack(spacing: 12) {
            icon()
            Text(title).font(.forma(12, bold: bold)).foregroundStyle(bold ? Theme.ink : Theme.muted).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8).frame(minHeight: 44).contentShape(Rectangle())
    }
}

private struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(duration: 0.2, bounce: 0), value: configuration.isPressed)
    }
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
