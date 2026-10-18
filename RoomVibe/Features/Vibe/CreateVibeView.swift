import PhotosUI
import SwiftUI

/// New vibe: pick photos -> one /vibe/profile call -> review and edit -> save (Paper frames M, N, O, P).
/// Nothing is stored until Save. `applyTo`: a room to link the saved vibe to.
struct CreateVibeView: View {
    let applyTo: UUID?

    @Environment(VibeLibrary.self) private var library
    @Environment(ProjectStore.self) private var store
    @Environment(Router.self) private var router
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase = Phase.pick
    @State private var picks: [Pick] = []
    @State private var selection: [PhotosPickerItem] = []
    @State private var draft: SavedVibe?
    @State private var analysis: Task<Void, Never>?
    @State private var notice: Notice?
    @State private var nameMissing = false
    @State private var sweep = false

    private enum Phase { case pick, finding, review }
    private enum Notice { case skipped(Int), failed(String), saveFailed(String) }
    private struct Pick: Identifiable { let id = UUID(); let data: Data; let image: UIImage }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            switch phase {
            case .pick: pickScreen
            case .finding: findingScreen
            case .review: reviewScreen
            }
        }
        .background(Theme.ground.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .onChange(of: selection) { loadSelection() }
        .onDisappear { analysis?.cancel() }
    }

    // MARK: Chrome

    private var topBar: some View {
        HStack {
            if phase != .finding {
                Button(action: back) {
                    Image(systemName: "chevron.left").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.ink)
                        .frame(width: 40, height: 40).background(Theme.tiles[0], in: Circle())
                }
                .accessibilityLabel("Back")
            }
            Spacer()
        }
        .frame(height: 44)
        .padding(.horizontal, 24).padding(.top, 8)
    }

    private func bottomBar<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content().padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 8)
    }

    // MARK: Pick (M)

    private var pickScreen: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Photos you love").font(.forma(24, bold: true, relativeTo: .title)).foregroundStyle(Theme.ink)
                            .accessibilityAddTraits(.isHeader)
                        Text(picks.isEmpty ? "Add up to \(VibeLibrary.maxImages)." : "\(picks.count) of \(VibeLibrary.maxImages)")
                            .font(.forma(12)).foregroundStyle(Theme.muted)
                            .contentTransition(.numericText(value: Double(picks.count)))
                    }
                    noticeCard
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                        ForEach(picks) { pick in
                            Color.clear.frame(height: 104)
                                .overlay { Image(uiImage: pick.image).resizable().scaledToFill() }
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                .overlay(alignment: .topTrailing) {
                                    Button { withAnimation(.spring(duration: 0.3, bounce: 0)) { picks.removeAll { $0.id == pick.id } } } label: {
                                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                                            .foregroundStyle(Theme.onSage)
                                            .frame(width: 24, height: 24).background(Theme.ink, in: Circle())
                                            .frame(width: 44, height: 44)   // tap target
                                    }
                                    .padding(.top, -10).padding(.trailing, -10)
                                    .accessibilityLabel("Remove photo")
                                }
                                .transition(.scale(scale: 0.9).combined(with: .opacity))
                        }
                        if picks.count < VibeLibrary.maxImages {
                            PhotosPicker(selection: $selection, maxSelectionCount: VibeLibrary.maxImages - picks.count,
                                         matching: .images) {
                                Image(systemName: "plus").font(.system(size: 18, weight: .regular))
                                    .foregroundStyle(Theme.wood)
                                    .frame(maxWidth: .infinity).frame(height: 104)
                                    .background(Theme.sand, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .strokeBorder(Theme.sage, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
                            }
                            .accessibilityLabel("Add photos")
                            .accessibilityIdentifier("addVibePhotos")
                        }
                    }
                }
                .padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            bottomBar {
                Button(action: find) {
                    HStack(spacing: 10) { Image(systemName: "sparkle"); Text("Find my vibe") }
                }
                .buttonStyle(PillButtonStyle())
                .disabled(picks.isEmpty)
                .opacity(picks.isEmpty ? 0.4 : 1)
                .accessibilityIdentifier("findVibe")
            }
        }
    }

    // MARK: Notices (P)

    @ViewBuilder private var noticeCard: some View {
        switch notice {
        case .skipped(let n):
            card("\(n) file\(n == 1 ? "" : "s") skipped. Only JPEG, PNG or HEIC photos work.")
        case .failed(let message):
            card("Couldn't find your vibe. \(message)", retry: find)
        case .saveFailed(let message):
            card("Couldn't save. \(message)")
        case nil:
            EmptyView()
        }
    }

    private func card(_ text: String, retry: (() -> Void)? = nil) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "exclamationmark.circle").font(.system(size: 15)).foregroundStyle(Theme.terracotta)
            Text(text).font(.forma(11)).foregroundStyle(Theme.ink).frame(maxWidth: .infinity, alignment: .leading)
            if let retry {
                Button("Retry", action: retry).font(.forma(12, bold: true)).foregroundStyle(Theme.ink)
                    .padding(.horizontal, 14).frame(height: 34).overlay(Capsule().strokeBorder(Theme.ink))
            }
            Button { notice = nil } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.wood)
                    .frame(width: 32, height: 32)
            }
            .accessibilityLabel("Dismiss")
        }
        .padding(.vertical, 10).padding(.leading, 16).padding(.trailing, 8)
        .background(Theme.sand, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.terracotta.opacity(0.35)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("vibeNotice")
    }

    // MARK: Finding (N)

    private var findingScreen: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 14) {
                let shown = Array(picks.prefix(4))
                VStack(spacing: 2) {
                    HStack(spacing: 2) { thumb(shown, 0); thumb(shown, 1) }
                    HStack(spacing: 2) { thumb(shown, 2); thumb(shown, 3) }
                }
                .frame(width: 132, height: 132)
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                .padding(.bottom, 12)
                Text("Finding your vibe").font(.forma(20, bold: true, relativeTo: .title2)).foregroundStyle(Theme.ink)
                Text("About 20 seconds").font(.forma(12)).foregroundStyle(Theme.muted)
                GeometryReader { geo in
                    Capsule().fill(Theme.hairline)
                        .overlay(alignment: .leading) {
                            Capsule().fill(Theme.sage).frame(width: geo.size.width * 0.4)
                                .offset(x: sweep ? geo.size.width * 0.6 : 0)
                        }
                        .clipShape(Capsule())
                }
                .frame(width: 200, height: 4).padding(.top, 6)
                .onAppear {
                    guard !reduceMotion else { return }
                    withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { sweep = true }
                }
            }
            .accessibilityElement(children: .combine)
            Spacer()
            bottomBar {
                Button("Cancel") { analysis?.cancel() }.buttonStyle(PillButtonStyle(filled: false))
                    .accessibilityIdentifier("cancelFind")
            }
        }
    }

    @ViewBuilder private func thumb(_ shown: [Pick], _ i: Int) -> some View {
        if i < shown.count {
            Color.clear.overlay { Image(uiImage: shown[i].image).resizable().scaledToFill() }.clipped()
        } else {
            Theme.hairline
        }
    }

    // MARK: Review (O)

    private var reviewScreen: some View {
        VStack(spacing: 0) {
            ScrollView {
                if let binding = Binding($draft) {
                    VStack(alignment: .leading, spacing: 20) {
                        noticeCard
                        VibeFields(vibe: binding, nameMissing: $nameMissing)
                    }
                    .padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 24)
                }
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            bottomBar {
                Button("Save vibe", action: save).buttonStyle(PillButtonStyle())
                    .accessibilityIdentifier("saveVibe")
            }
        }
    }

    // MARK: Actions

    private func back() {
        switch phase {
        case .pick: router.path.removeLast()
        case .review: phase = .pick; draft = nil; nameMissing = false; notice = nil   // photos stay; Find My Vibe runs again
        case .finding: break
        }
    }

    private func loadSelection() {
        let items = selection
        selection = []
        guard !items.isEmpty else { return }
        Task {
            var skipped = 0
            for item in items {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let jpeg = await Task.detached(operation: { resizedVibeJPEG(data) }).value,
                   let image = UIImage(data: jpeg), picks.count < VibeLibrary.maxImages {
                    picks.append(Pick(data: jpeg, image: image))
                } else {
                    skipped += 1
                }
            }
            if skipped > 0 { notice = .skipped(skipped) }
        }
    }

    private func find() {
        guard phase != .finding, !picks.isEmpty else { return }
        notice = nil
        phase = .finding
        let images = picks.map(\.data)
        analysis = Task {
            do {
                draft = SavedVibe(profile: try await APIClient.shared.extractVibe(images))
                phase = .review
            } catch is CancellationError {
                phase = .pick
            } catch {
                notice = .failed(error.localizedDescription)
                phase = .pick
            }
        }
    }

    private func save() {
        guard let draft else { return }
        guard !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { nameMissing = true; return }
        do {
            let saved = try library.add(draft, images: picks.map(\.data))
            if let applyTo, var room = store.projects.first(where: { $0.id == applyTo }) {
                room.vibeID = saved.id
                store.update(room)
                router.path.removeLast()   // back to the room, now wearing the vibe
            } else {
                router.path.removeLast()
                router.path.append(.vibe(saved.id))
            }
        } catch {
            notice = .saveFailed(error.localizedDescription)
        }
    }
}
