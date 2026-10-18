import SwiftUI

/// Pieces shared by the Home, Room detail and Object detail screens (Paper "forma" design).

/// Brand mark: a heavy square ring with one sage square inside. `inset` moves the square on its 200-unit grid
/// (default = bottom-right, as in the logo).
struct Logo: View {
    var size: CGFloat = 112
    var square = CGPoint(x: 128, y: 128)   // center of the sage square, 0...200

    var body: some View {
        Canvas { ctx, s in
            let u = s.width / 200
            ctx.stroke(Path(CGRect(x: 14 * u, y: 14 * u, width: 172 * u, height: 172 * u)),
                       with: .color(Color(hex: 0x2B2118)), lineWidth: 28 * u)
            ctx.fill(Path(CGRect(x: (square.x - 30) * u, y: (square.y - 30) * u, width: 60 * u, height: 60 * u)),
                     with: .color(Theme.sage))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// "forma" in Space Mono Bold with hand-set gaps (em): f–o is tight, r–m and m–a open up so the mono cells read evenly.
struct Wordmark: View {
    var size: CGFloat = 24
    private static let gaps: [CGFloat] = [0.125, 0.25, 0.29, 0.32]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array("forma".enumerated()), id: \.offset) { i, letter in
                Text(String(letter)).font(.custom("SpaceMono-Bold", fixedSize: size))
                if i < Self.gaps.count { Color.clear.frame(width: Self.gaps[i] * size, height: 1) }
            }
        }
        .foregroundStyle(Color(hex: 0x2B2118))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("forma")
    }
}

/// Glass-free sand pill with a sage outline and sparkle: starts the photoreal render of the room.
/// `compact` is the icon-only circle used when the Objects panel covers the room.
struct MakeItRealButton: View {
    var compact = false
    /// Defaults are the sand pill; fullscreen passes inverted colors when the backdrop is light.
    var fill = Theme.sand
    var ink = Theme.ink
    var sparkle = Theme.sageDeep
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").font(.system(size: compact ? 18 : 15, weight: .semibold)).foregroundStyle(sparkle)
                if !compact { Text("Make it real").font(.forma(12, bold: true)).foregroundStyle(ink) }
            }
            .padding(.horizontal, compact ? 0 : 16)
            .frame(width: compact ? 44 : nil, height: 44)
            .background(fill, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.sage, lineWidth: 1.5))
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel("Make it real")
    }

    private struct PressStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .opacity(configuration.isPressed ? 0.7 : 1)
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .animation(.spring(duration: 0.25, bounce: 0), value: configuration.isPressed)
        }
    }
}

/// Stylised room thumbnail: back wall, floor, one piece of furniture.
struct RoomGlyph: View {
    var body: some View {
        Canvas { ctx, size in
            let u = size.width / 64
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.hairline))
            ctx.fill(Path(CGRect(x: 14 * u, y: 14 * u, width: 36 * u, height: 28 * u)), with: .color(Color(hex: 0xBDB1A1)))
            ctx.fill(Path(CGRect(x: 0, y: 42 * u, width: size.width, height: 22 * u)), with: .color(Color(hex: 0xD8CCBB)))
            ctx.fill(Path(roundedRect: CGRect(x: 18 * u, y: 34 * u, width: 28 * u, height: 12 * u), cornerRadius: 2 * u),
                     with: .color(Theme.wood))
        }
        .accessibilityHidden(true)
    }
}

/// "‹ Rooms" circle-and-label on the left, outlined action on the right.
struct DetailBar: View {
    let backTitle: String
    let actionTitle: String
    let actionIcon: String
    var actionDisabled = false
    let back: () -> Void
    let action: () -> Void

    var body: some View {
        HStack {
            Button(action: back) {
                HStack(spacing: 10) {
                    Image(systemName: "chevron.left").font(.system(size: 14, weight: .semibold))
                        .frame(width: 40, height: 40).background(Theme.tiles[0], in: Circle())
                    Text(backTitle).font(.forma(13))
                }
                .foregroundStyle(Theme.ink)
            }
            .accessibilityLabel("Back to \(backTitle)")
            Spacer()
            Button(action: action) {
                Label(actionTitle, systemImage: actionIcon).font(.forma(13)).foregroundStyle(Theme.ink)
                    .padding(.horizontal, 16).frame(height: 40)
                    .overlay(Capsule().strokeBorder(Theme.ink, lineWidth: 1))
            }
            .disabled(actionDisabled)
            .opacity(actionDisabled ? 0.4 : 1)
        }
    }
}

/// Small "Name" caption over a big editable title with a rule and pencil.
struct NameField: View {
    @Binding var text: String
    let commit: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Name").font(.forma(11)).foregroundStyle(Theme.muted)
            HStack {
                TextField("Name", text: $text)
                    .font(.forma(28, bold: true, relativeTo: .title)).foregroundStyle(Theme.ink)
                    .focused($focused).submitLabel(.done).onSubmit(commit)
                Image(systemName: "pencil").foregroundStyle(Theme.ink)
                    .onTapGesture { focused = true }
            }
            Theme.ink.frame(height: 1)
        }
        .onChange(of: focused) { _, now in if !now { commit() } }
    }
}

/// Label over value, e.g. "Width / 5.0 m".
struct Measure: View {
    let label: String, value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.forma(11)).foregroundStyle(Theme.muted)
            Text(value).font(.forma(17, bold: true)).foregroundStyle(Theme.ink)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// Rounded tinted tile that holds a 3D view.
struct StageCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .frame(maxWidth: .infinity).frame(height: 300)
            .background(Color(hex: 0xE8DFD3))
            .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
    }
}

struct SearchField: View {
    @Binding var text: String
    let prompt: String
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted)
            TextField("", text: $text, prompt: Text(prompt).foregroundStyle(Theme.muted))
                .font(.forma(14)).foregroundStyle(Theme.ink).autocorrectionDisabled()
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.ink) }
                    .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 16).frame(height: 44)
        .background(Theme.hairline, in: Capsule())
    }
}

/// Dark capsule that confirms an action ("Chair added").
struct Toast: View {
    let text: String
    var body: some View {
        Label { Text(text).font(.forma(13)) } icon: {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.sage)
        }
        .foregroundStyle(Theme.onSage)
        .padding(.horizontal, 16).frame(height: 44)
        .background(Theme.ink, in: Capsule())
    }
}

/// "5.0 × 4.0 m · 3 items" for a room (nil until its scan loads).
@MainActor
func roomSummary(_ project: Project, store: ProjectStore) -> String? {
    guard let room = store.room(for: project) else { return nil }
    let (lo, hi) = RoomBuilder.bounds(room)
    let n = roomItemCount(project, room: room)
    return String(format: "%.1f × %.1f m · %d item%@", hi.x - lo.x, hi.z - lo.z, n, n == 1 ? "" : "s")
}

func roomItemCount(_ project: Project, room: RoomModel) -> Int {
    project.placements.count + room.objects.indices.filter { !(project.hiddenRoomObjects?.contains($0) ?? false) && !(project.removedRoomObjects?.contains($0) ?? false) }.count
}
