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
        let step = phase == .pick ? 1 : phase == .finding ? 2 : 3
        return ZStack {
            Text("New vibe · \(step) of 3").font(.forma(12)).foregroundStyle(Theme.muted)
            HStack {
                if phase != .finding {
                    Button(action: back) {
                        Image(systemName: "chevron.left").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.wood)
                            .frame(width: 44, height: 44).background(Theme.sand, in: Circle())
                    }
                    .accessibilityLabel("Back")
                }
                Spacer()
            }
        }
        .padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 8)
    }

    private func bottomBar<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 8)
            .background(Theme.ground)
            .overlay(alignment: .top) { Theme.hairline.frame(height: 1) }
    }

    private func heading(_ text: String) -> some View {
        Text(text).font(.system(size: 34, weight: .semibold, design: .serif)).tracking(-0.34)
            .foregroundStyle(Theme.ink).accessibilityAddTraits(.isHeader)
    }

    // MARK: Pick (M)

    private var pickScreen: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    noticeCard
                    VStack(alignment: .leading, spacing: 8) {
                        heading("Add inspiration photos")
                        Text("Pick 1 to \(VibeLibrary.maxImages) photos of looks you love. JPEG, PNG or HEIC.")
                            .font(.forma(12)).foregroundStyle(Theme.muted)
                    }
                    HStack {
                        Text("Photos").font(.forma(13, bold: true)).foregroundStyle(Theme.ink)
                        Spacer()
                        Text("\(picks.count) / \(VibeLibrary.maxImages)").font(.forma(12)).foregroundStyle(Theme.muted)
                    }
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                        ForEach(picks) { pick in
                            Color.clear.frame(height: 104)
                                .overlay { Image(uiImage: pick.image).resizable().scaledToFill() }
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                .overlay(alignment: .topTrailing) {
                                    Button { picks.removeAll { $0.id == pick.id } } label: {
                                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                                            .foregroundStyle(Theme.onSage)
                                            .frame(width: 24, height: 24).background(Theme.ink, in: Circle())
                                            .frame(width: 44, height: 44)   // tap target
                                    }
                                    .padding(.top, -10).padding(.trailing, -10)
                                    .accessibilityLabel("Remove photo")
                                }
                        }
                        if picks.count < VibeLibrary.maxImages {
                            PhotosPicker(selection: $selection, maxSelectionCount: VibeLibrary.maxImages - picks.count,
                                         matching: .images) {
                                VStack(spacing: 6) {
                                    Image(systemName: "plus").font(.system(size: 18, weight: .regular))
                                    Text("Add").font(.forma(11))
                                }
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
                .padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            bottomBar {
                Button(action: find) {
                    HStack(spacing: 10) { Image(systemName: "sparkle"); Text("Find My Vibe") }
                }
                .buttonStyle(PillButtonStyle())
                .disabled(picks.isEmpty)
                .opacity(picks.isEmpty ? 0.5 : 1)
                .accessibilityIdentifier("findVibe")
            }
        }
    }

    // MARK: Notices (P)

    @ViewBuilder private var noticeCard: some View {
        switch notice {
        case .skipped(let n):
            card(title: "\(n) file\(n == 1 ? "" : "s") skipped",
                 text: "Only JPEG, PNG or HEIC photos work. \(n == 1 ? "It was" : "They were") not added.") {
                Button { notice = nil } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.wood)
                        .frame(width: 32, height: 32)
                }
                .accessibilityLabel("Dismiss")
            }
        case .failed(let message):
            card(title: "Couldn't find your vibe", text: "\(message) Your photos are kept.") {
                EmptyView()
            } actions: {
                HStack(spacing: 8) {
                    Button("Retry", action: find).font(.forma(12)).foregroundStyle(Theme.onSage)
                        .padding(.horizontal, 20).frame(height: 40).background(Theme.sage, in: Capsule())
                    Button("Back to photos") { notice = nil }.font(.forma(12)).foregroundStyle(Theme.ink)
                        .padding(.horizontal, 20).frame(height: 40).overlay(Capsule().strokeBorder(Theme.ink))
                }
            }
        case .saveFailed(let message):
            card(title: "Couldn't save", text: message) { EmptyView() }
        case nil:
            EmptyView()
        }
    }

    private func card<Trailing: View, Actions: View>(title: String, text: String,
                                                      @ViewBuilder trailing: () -> Trailing,
                                                      @ViewBuilder actions: () -> Actions = { EmptyView() }) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.circle").font(.system(size: 18)).foregroundStyle(Theme.terracotta)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.forma(12, bold: true)).foregroundStyle(Theme.ink)
                    Text(text).font(.forma(11)).foregroundStyle(Theme.wood)
                }
                Spacer(minLength: 0)
                trailing()
            }
            actions()
        }
        .padding(.vertical, 14).padding(.horizontal, 16)
        .background(Color(hex: 0xF3E1D5), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color(hex: 0xE5C5B0)))
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
                Text("Finding your vibe").font(.system(size: 26, weight: .semibold, design: .serif)).foregroundStyle(Theme.ink)
                Text("Reading \(picks.count) photo\(picks.count == 1 ? "" : "s") for palette, materials and mood.\nThis takes about 20 seconds.")
                    .font(.forma(12)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
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
                if let binding = Binding($draft) { reviewFields(binding) }
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            bottomBar {
                Button("Save Vibe", action: save).buttonStyle(PillButtonStyle())
                    .accessibilityIdentifier("saveVibe")
            }
        }
    }

    private func reviewFields(_ vibe: Binding<SavedVibe>) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            noticeCard
            VStack(alignment: .leading, spacing: 6) {
                Text("NAME · SUGGESTED BY AI").font(.forma(10)).tracking(0.6).foregroundStyle(Theme.muted)
                HStack {
                    TextField("", text: vibe.name, prompt: Text("Name your vibe").foregroundStyle(Color(hex: 0xC9BBA4)))
                        .font(.system(size: 34, weight: .semibold, design: .serif)).foregroundStyle(Theme.ink)
                        .accessibilityIdentifier("vibeName")
                        .onChange(of: vibe.wrappedValue.name) { nameMissing = false }
                    Image(systemName: "pencil").font(.system(size: 14)).foregroundStyle(Theme.wood)
                }
                .padding(.bottom, 10)
                .overlay(alignment: .bottom) {
                    (nameMissing ? Color(hex: 0xC98F6B) : Theme.sage).frame(height: 1.5)
                }
                if nameMissing {
                    Text("A vibe needs a name before it can be saved.").font(.forma(11)).foregroundStyle(Theme.terracotta)
                }
            }
            if !vibe.wrappedValue.colors.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Colors").font(.forma(13, bold: true)).foregroundStyle(Theme.ink)
                    SwatchRow(colors: vibe.wrappedValue.colors, showHex: true)
                }
            }
            TagEditor(title: "Styles", tags: vibe.styles)
            TagEditor(title: "Mood", tags: vibe.mood)
            TagEditor(title: "Materials", tags: vibe.materials)
            TagEditor(title: "Textures", tags: vibe.textures)
            TagEditor(title: "Motifs", tags: vibe.motifs)
            TagEditor(title: "Lighting", tags: vibe.lighting)
            TagEditor(title: "Furniture", tags: vibe.furnitureCharacteristics)
            TagEditor(title: "Avoid", tags: vibe.avoid, avoid: true)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Description").font(.forma(13, bold: true)).foregroundStyle(Theme.ink)
                    Spacer()
                    Text("\(vibe.wrappedValue.description.split(whereSeparator: \.isWhitespace).count) words")
                        .font(.forma(11)).foregroundStyle(Theme.muted)
                }
                field(vibe.description, prompt: "What this aesthetic is about", filled: true)
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("Custom instructions").font(.forma(13, bold: true)).foregroundStyle(Theme.ink)
                field(vibe.customInstructions, prompt: "Optional. e.g. keep the existing sofa, no dark colors.", filled: false)
            }
        }
        .padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 24)
    }

    private func field(_ text: Binding<String>, prompt: String, filled: Bool) -> some View {
        TextField("", text: text, prompt: Text(prompt).foregroundStyle(Theme.muted), axis: .vertical)
            .font(.forma(12)).foregroundStyle(Theme.ink).lineLimit(3...14)
            .padding(16)
            .background(filled ? Theme.sand : .clear, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.hairline))
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
