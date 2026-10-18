import SwiftUI

/// Paper frames "v2 · Q · Vibe details" and "v2 · R · delete confirm". Edits save as you go, like a room's name.
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
                if confirmDelete { deleteCard(saved) }
            }
        }
        .animation(.spring(duration: 0.25, bounce: 0), value: confirmDelete)
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { if draft == nil { draft = library.vibe(vibeID) } }
        .task(id: draft) {   // autosave, debounced so typing doesn't write on every key
            try? await Task.sleep(for: .milliseconds(600))
            if !Task.isCancelled { save() }
        }
        .onDisappear(perform: save)
    }

    private func content(_ saved: SavedVibe, _ vibe: Binding<SavedVibe>) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                DetailBar(backTitle: "Vibes", actionTitle: "Delete", actionIcon: "trash",
                          back: { router.path.removeLast() }, action: { confirmDelete = true })
                    .accessibilityIdentifier("vibeBar")
                VibeCollage(vibe: saved)
                VibeFields(vibe: vibe, nameMissing: $nameError,
                           caption: rooms.isEmpty ? "Not in a room yet" : "In \(rooms.joined(separator: ", "))")
                if let notice { Text(notice).font(.forma(11)).foregroundStyle(Theme.terracotta) }
            }
            .padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 28)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
    }

    private func deleteCard(_ saved: SavedVibe) -> some View {
        ZStack {
            Theme.ink.opacity(0.4).ignoresSafeArea().onTapGesture { confirmDelete = false }
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Delete this vibe?").font(.forma(20, bold: true)).foregroundStyle(Theme.ink)
                    Text("Its photos are removed too. This can't be undone.")
                        .font(.forma(12)).lineSpacing(4).foregroundStyle(Theme.muted)
                }
                VStack(spacing: 10) {
                    Button("Delete") { delete(saved) }
                        .font(.forma(14)).foregroundStyle(Theme.onSage)
                        .frame(maxWidth: .infinity, minHeight: 48).background(Theme.terracotta, in: Capsule())
                        .accessibilityIdentifier("confirmDelete")
                    Button("Keep") { confirmDelete = false }.buttonStyle(PillButtonStyle(filled: false))
                }
            }
            .padding(24)
            .background(Theme.ground, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .padding(.horizontal, 32)
        }
        .transition(.opacity)
    }

    /// Writes the draft when it differs from the library. A blank name is kept as a draft, not saved.
    private func save() {
        guard let draft, draft != library.vibe(vibeID) else { return }
        guard !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { nameError = true; return }
        do {
            try library.update(draft)
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
