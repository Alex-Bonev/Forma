import SwiftUI

/// Paper frames "v2 · Q · Vibe details" and "v2 · R · delete confirm". Edits stay in `draft` until Save Changes.
struct VibeDetailView: View {
    @Environment(VibeLibrary.self) private var library
    @Environment(ProjectStore.self) private var store
    @Environment(Router.self) private var router
    let vibeID: UUID
    @State private var draft: SavedVibe?
    @State private var confirmDelete = false
    @State private var nameError = false
    @State private var notice: String?

    private var saved: SavedVibe? { library.vibe(vibeID) }
    private var rooms: [String] { store.projects.filter { $0.vibeID == vibeID }.map(\.name) }

    var body: some View {
        ZStack {
            Theme.ground.ignoresSafeArea()
            if let saved, let binding = Binding($draft) {
                content(saved, binding)
                    .safeAreaInset(edge: .bottom, spacing: 0) { actions(saved) }
                if confirmDelete { deleteCard(saved) }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { if draft == nil { draft = library.vibe(vibeID) } }
    }

    private func content(_ saved: SavedVibe, _ vibe: Binding<SavedVibe>) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Button { router.path.removeLast() } label: {
                    Image(systemName: "chevron.left").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.wood)
                        .frame(width: 44, height: 44).background(Theme.sand, in: Circle())
                }
                .accessibilityLabel("Back")
                .padding(.top, 12)

                VStack(alignment: .leading, spacing: 6) {
                    TextField("", text: vibe.name, prompt: Text("Name your vibe").foregroundStyle(Theme.muted.opacity(0.6)))
                        .font(.system(size: 34, weight: .semibold, design: .serif)).foregroundStyle(Theme.ink)
                        .onChange(of: vibe.wrappedValue.name) { nameError = false }
                        .accessibilityIdentifier("vibeName")
                    if nameError {
                        Rectangle().fill(Theme.terracotta).frame(height: 1)
                        Text("A vibe needs a name before it can be saved.").font(.forma(11)).foregroundStyle(Theme.terracotta)
                    } else {
                        Text(rooms.isEmpty ? "Not in a room yet" : "Used in \(rooms.joined(separator: ", "))")
                            .font(.forma(11)).foregroundStyle(Theme.muted)
                    }
                }
                .padding(.top, 20)

                VibeCollage(vibe: saved).padding(.top, 20)

                section("Colors") { SwatchRow(colors: vibe.wrappedValue.colors) }
                section("Tags", spacing: 18) {
                    TagEditor(title: "Styles", tags: vibe.styles)
                    TagEditor(title: "Mood", tags: vibe.mood)
                    TagEditor(title: "Materials", tags: vibe.materials)
                    TagEditor(title: "Textures", tags: vibe.textures)
                    TagEditor(title: "Motifs", tags: vibe.motifs)
                    TagEditor(title: "Lighting", tags: vibe.lighting)
                    TagEditor(title: "Furniture", tags: vibe.furnitureCharacteristics)
                    TagEditor(title: "Avoid", tags: vibe.avoid, avoid: true)
                }
                section("Description", spacing: 8) {
                    TextField("", text: vibe.description, axis: .vertical)
                        .font(.forma(12)).foregroundStyle(Theme.wood).lineSpacing(5)
                }
                section("Custom instructions", spacing: 8) {
                    TextField("", text: vibe.customInstructions,
                              prompt: Text("Optional. e.g. keep the existing sofa, no dark colors.").foregroundStyle(Theme.muted),
                              axis: .vertical)
                        .font(.forma(12)).foregroundStyle(Theme.ink).lineSpacing(5).lineLimit(2...)
                        .padding(.horizontal, 16).padding(.vertical, 14)
                        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.hairline))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Created \(saved.createdAt.formatted(.dateTime.month(.abbreviated).day().year()))")
                    Text("Updated \(saved.updatedAt.formatted(.dateTime.month(.abbreviated).day().year()))")
                    if let notice { Text(notice).foregroundStyle(Theme.terracotta).padding(.top, 6) }
                }
                .font(.forma(11)).foregroundStyle(Theme.muted).padding(.top, 24)
            }
            .padding(.horizontal, 24).padding(.bottom, 28)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
    }

    private func section<C: View>(_ title: String, spacing: CGFloat = 12, @ViewBuilder _ body: () -> C) -> some View {
        VStack(alignment: .leading, spacing: spacing) {
            Text(title).font(.forma(13, bold: true)).foregroundStyle(Theme.ink)
            body()
        }
        .padding(.top, 28)
    }

    private func actions(_ saved: SavedVibe) -> some View {
        HStack(spacing: 10) {
            Button("Save Changes") { save() }
                .buttonStyle(PillButtonStyle())
                .disabled(draft == saved)
                .opacity(draft == saved ? 0.4 : 1)
                .accessibilityIdentifier("saveChanges")
            Button { confirmDelete = true } label: {
                HStack(spacing: 8) { Image(systemName: "trash"); Text("Delete") }
            }
            .buttonStyle(PillButtonStyle(filled: false))
            .accessibilityIdentifier("deleteVibe")
        }
        .padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 8)
        .background(Theme.ground)
        .overlay(alignment: .top) { Theme.hairline.frame(height: 1) }
    }

    private func deleteCard(_ saved: SavedVibe) -> some View {
        ZStack {
            Theme.ink.opacity(0.4).ignoresSafeArea().onTapGesture { confirmDelete = false }
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Delete this vibe?").font(.system(size: 26, weight: .semibold, design: .serif)).foregroundStyle(Theme.ink)
                    Text("Its photos and profile are removed from this device. This can't be undone.")
                        .font(.forma(12)).lineSpacing(5).foregroundStyle(Theme.wood)
                }
                VStack(spacing: 10) {
                    Button("Delete") { delete(saved) }
                        .font(.forma(14)).foregroundStyle(Theme.onSage)
                        .frame(maxWidth: .infinity, minHeight: 48).background(Theme.terracotta, in: Capsule())
                        .accessibilityIdentifier("confirmDelete")
                    Button("Keep vibe") { confirmDelete = false }.buttonStyle(PillButtonStyle(filled: false))
                }
            }
            .padding(24)
            .background(Theme.ground, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .padding(.horizontal, 32)
        }
        .transition(.opacity)
    }

    private func save() {
        guard let draft else { return }
        guard !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { nameError = true; return }
        do {
            try library.update(draft)
            self.draft = library.vibe(vibeID)
            notice = nil
        } catch {
            notice = "Couldn't save: \(error.localizedDescription)"
        }
    }

    private func delete(_ saved: SavedVibe) {
        do {
            try library.delete(saved)
        } catch {
            confirmDelete = false
            notice = "Couldn't delete: \(error.localizedDescription)"
            return
        }
        for var room in store.projects where room.vibeID == saved.id { room.vibeID = nil; store.update(room) }
        router.path.removeLast()
    }
}
