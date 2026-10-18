import ImageIO
import PhotosUI
import SwiftUI

/// Vibe mode: an inspiration photo and/or a description -> /vibe/analyze -> restyled render (/render with the style
/// and the photo as reference) + real products found by shopping agents (/vibe/shop), within the budget if one was
/// given. Falls back to quick search (/vibe/products) per item. Pushed from RenderView's navigation stack.
/// A room with a saved vibe starts from it: its first photo is the reference and its profile the description.
struct VibeView: View {
    @Environment(ProjectStore.self) private var store
    @Environment(VibeLibrary.self) private var library
    @State private var useRoomVibe = true
    @State private var model: VibeModel
    @State private var pick: PhotosPickerItem?
    @State private var photo: UIImage?
    @State private var prompt = ""
    @State private var budget: Double?
    @State private var showBudgetSheet = false
    @FocusState private var promptFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showCart = false
    @State private var cartFrame: CGRect = .zero
    /// Adds whose square is still in the air: the cart count lags the real one by this much.
    @State private var landing = 0
    @State private var pickedVibeID: UUID?
    @State private var showVibeMenu = false
    @State private var pulse = 0
    @State private var flight: Flight?
    private let preset: UIImage?

    private struct Flight: Identifiable {
        let id = UUID()
        let imageURL: URL?
        let from: CGRect
    }

    private var cartCount: Int {
        model.projectID == nil ? 0 : RoomCart.count(in: store.projects, room: model.projectID)
    }

    /// `inspiration`: optional preset photo (e.g. a bundled demo image) that starts the flow immediately.
    /// `grounding`: Make it real's layout, structure map and view for this snapshot, so the restyle keeps the room.
    init(snapshot: UIImage, projectID: UUID? = nil, inspiration: UIImage? = nil,
         grounding: (() async -> RenderGrounding)? = nil) {
        _model = State(initialValue: VibeModel.forRoom(projectID, snapshot: snapshot, grounding: grounding))
        preset = inspiration
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                input
                if let error = model.error { errorCard(error) { model.retryAnalyze() } }
                if model.started { styleSection.transition(sectionTransition) }
                if model.style != nil {
                    renderSection.transition(sectionTransition)
                    if model.shopRows != nil || model.shopError != nil {
                        shoppingSection.transition(sectionTransition)
                    } else {
                        productsSection.transition(sectionTransition)
                    }
                }
            }
            .animation(sectionSpring, value: model.started)
            .animation(sectionSpring, value: model.style != nil)
            .animation(sectionSpring, value: model.shopRows != nil)
            .padding(.vertical, 16)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.ground.ignoresSafeArea())
        .navigationTitle("Shop a vibe")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.ground, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Shop a vibe").font(.forma(14, bold: true)).foregroundStyle(Theme.ink)
            }
            // Slot stays once the room has items, so the flying square has a steady target.
            if cartCount > 0 {
                ToolbarItem(placement: .topBarTrailing) {
                    CartButton(count: cartCount - landing, size: 44, plain: true) { showCart = true }
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { cartFrame = $0 }
                }
            }
        }
        .sheet(isPresented: $showCart) { CartSheet(projectID: model.projectID) }
        .sheet(isPresented: $showBudgetSheet) {
            BudgetSheet(current: model.budgetUSD, picksTotal: model.totalUSD) { new in changeBudget(new) }
        }
        .onChange(of: model.style?.budgetUsd) { _, parsed in
            if budget == nil, let parsed { budget = parsed }   // only fills an empty field
        }
        .onChange(of: budget) { _, new in saveBudget(new) }
        .onChange(of: model.settledBudget) { _, settled in
            if let settled { saveBudget(settled) }   // a reset run (nil) leaves the room's budget alone
        }
        .overlay { flightLayer }
        .tint(Theme.ink)
        .environment(\.colorScheme, .light)   // Paper is light-only
        .onAppear {
            // The room's budget, unless a restored run shows a different one.
            if budget == nil, model.budgetUSD == nil || model.budgetUSD == room?.budgetUSD { budget = room?.budgetUSD }
            if let preset, !model.started {
                photo = preset
                model.begin(with: preset, prompt: "")
            }
        }
        .onDisappear { if model.projectID == nil { model.cancel() } }   // a room's run keeps going
        .onChange(of: pick) {
            guard let item = pick else { return }
            pick = nil   // so picking the same photo again still fires
            Task {
                do {
                    guard let data = try await item.loadTransferable(type: Data.self),
                          let image = await Task.detached(operation: { downsampled(data) }).value else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                    photo = image
                } catch {
                    model.fail("Couldn't open that photo. Try another one.")
                }
            }
        }
    }

    private var sectionSpring: Animation? { reduceMotion ? nil : .spring(duration: 0.4, bounce: 0.1) }
    private var sectionTransition: AnyTransition {
        reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity)
    }
    private var menuSpring: Animation? { reduceMotion ? nil : .spring(duration: 0.28, bounce: 0.12) }

    private var room: Project? { store.projects.first { $0.id == model.projectID } }

    /// The room owns the budget (nil = no limit). The demo run never writes it.
    private func saveBudget(_ usd: Double?) {
        guard !model.isDemo, var room, room.budgetUSD != usd else { return }
        room.budgetUSD = usd
        store.update(room)
    }

    /// Budget sheet or Raise budget: re-picks the set and saves the choice, No limit included.
    private func changeBudget(_ usd: Double?) {
        saveBudget(usd)
        budget = usd   // the field follows, so the next run uses it
        Task { await model.applyBudget(usd) }
    }
    /// The room's saved vibe, unless the user set it aside for this screen.
    private var roomVibe: SavedVibe? {
        if let pickedVibeID, let vibe = library.vibe(pickedVibeID) { return vibe }   // this run only, never saved to the room
        return useRoomVibe ? room?.vibeID.flatMap(library.vibe) : nil
    }

    private func setVibeMenu(_ open: Bool) { withAnimation(menuSpring) { showVibeMenu = open } }

    /// Expands the vibe dropdown in place under a header; the fields below slide down instead of being covered.
    private func withVibeMenu(_ header: some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if showVibeMenu {
                VibeDropdownMenu(header: "SHOP FROM", selected: roomVibe?.id,
                                 clearTitle: roomVibe != nil ? "Describe a different look" : nil,
                                 newTitle: "",   // no route to the new-vibe flow from inside this sheet
                                 onSelect: { id in pickedVibeID = id; setVibeMenu(false) },
                                 onClear: { useRoomVibe = false; pickedVibeID = nil; setVibeMenu(false) },
                                 onNew: { setVibeMenu(false) })
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.96, anchor: .top).combined(with: .opacity))
            }
        }
    }

    private var vibeChevron: some View {
        Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.muted)
            .rotationEffect(.degrees(showVibeMenu ? 180 : 0))
            .animation(menuSpring, value: showVibeMenu)
    }

    private var canStart: Bool {
        roomVibe != nil || photo != nil || !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var input: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let vibe = roomVibe { vibeHeader(vibe) } else { freeHeader }
            TextField("", text: $prompt, prompt: Text(roomVibe == nil ? "Cozy reading nook, warm wood, under $800"
                                                                      : "Anything else? e.g. under $800").foregroundStyle(Theme.muted),
                      axis: .vertical)
                .font(.forma(12)).foregroundStyle(Theme.ink)
                .lineLimit(1...4)
                .padding(16)
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.hairline))
                .focused($promptFocused)
                .submitLabel(.go)
                .onSubmit(start)
                .accessibilityIdentifier("vibePrompt")
            BudgetField(amount: $budget)
            Button(action: start) {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                    Text(model.started ? "Try again" : "Restyle and shop")
                }
            }
            .buttonStyle(PillButtonStyle())
            .disabled(!canStart)
            .opacity(canStart ? 1 : 0.4)
            .accessibilityIdentifier("vibeStart")
        }
        .padding(.horizontal, 24)
    }

    /// The room's saved vibe as the input; x sets it aside for a one-off photo or description.
    private func vibeHeader(_ vibe: SavedVibe) -> some View {
        withVibeMenu(HStack(spacing: 14) {
            HStack(spacing: 14) {
                VibeTile(vibe: vibe, corner: 16).frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text(vibe.name).font(.forma(20, bold: true, relativeTo: .title2)).foregroundStyle(Theme.ink).lineLimit(2)
                    Text(pickedVibeID == nil ? "\(room?.name ?? "This room")'s vibe" : "Picked for this run")
                        .font(.forma(11)).foregroundStyle(Theme.muted)
                }
                vibeChevron
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .onTapGesture { setVibeMenu(!showVibeMenu) }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("vibeHeaderDropdown")
            Button { useRoomVibe = false; pickedVibeID = nil } label: {
                Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.wood)
                    .frame(width: 32, height: 32).background(Theme.sand, in: Circle())
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .accessibilityLabel("Use another look")
        })
        .accessibilityIdentifier("roomVibeInput")
    }

    private var freeHeader: some View {
        withVibeMenu(freeHeaderRow)
    }

    private var freeHeaderRow: some View {
        HStack(alignment: .top, spacing: 14) {
            PhotosPicker(selection: $pick, matching: .images) {
                Group {
                    if let photo {
                        Image(uiImage: photo).resizable().scaledToFill()
                    } else {
                        VStack(spacing: 4) {
                            Image(systemName: "plus").font(.system(size: 16))
                            Text("Photo").font(.forma(10))
                        }
                        .foregroundStyle(Theme.wood)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Theme.sand)
                    }
                }
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.hairline))
            }
            .accessibilityLabel(photo == nil ? "Add an inspiration photo" : "Change the inspiration photo")
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("Describe a vibe").font(.forma(20, bold: true, relativeTo: .title2)).foregroundStyle(Theme.ink)
                    vibeChevron
                }
                    // Hidden stage trigger (kept in Release): long-press the title on a fresh screen to show the
                    // bundled demo result.
                    .onLongPressGesture(minimumDuration: 0.8) {
                        if !model.started, let demo = VibeDemo.load() { prompt = demo.prompt; model.showDemo(demo) }
                    }
                Text("A photo, words, or both.")
                    .font(.forma(11)).foregroundStyle(Theme.muted)
            }
            .contentShape(Rectangle())
            .onTapGesture { setVibeMenu(!showVibeMenu) }
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("vibeHeaderDropdown")
            Spacer(minLength: 0)
            if photo != nil {
                Button { photo = nil } label: {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.wood)
                        .frame(width: 32, height: 32).background(Theme.sand, in: Circle())
                        .frame(width: 44, height: 44).contentShape(Rectangle())   // 44 pt hit target
                }
                .accessibilityLabel("Remove photo")
            }
        }
    }

    private func start() {
        guard canStart else { return }
        promptFocused = false
        model.budgetOverride = budget
        if let budget { saveBudget(budget) }
        let typed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if let vibe = roomVibe, let room {
            // What the user typed goes first so a budget survives the backend's prompt cap.
            let brief = [typed, getRoomVibeBrief(room: room, library: library) ?? ""].filter { !$0.isEmpty }
                .joined(separator: "\n")
            let image = vibe.imageFiles.first.flatMap { UIImage(contentsOfFile: library.imageURL(vibe, $0).path) }
            model.begin(with: image, prompt: String(brief.prefix(VibeModel.maxPrompt)))
        } else {
            model.begin(with: photo, prompt: typed)
        }
    }

    @ViewBuilder private var styleSection: some View {
        if let style = model.style {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    if roomVibe == nil {   // a room vibe already names the look above
                        Text(style.styleName).font(.forma(20, bold: true, relativeTo: .title2)).foregroundStyle(Theme.ink)
                    }
                    if model.isDemo {
                        Text("Saved demo result").font(.forma(10)).foregroundStyle(Theme.muted)
                    } else if let at = model.savedAt {
                        Text("Last run · \(at.formatted(.relative(presentation: .named))) · Try again to redo")
                            .font(.forma(10)).foregroundStyle(Theme.muted)
                    }
                }
                HStack(spacing: 8) {
                    ForEach(Array(style.palette.prefix(5).enumerated()), id: \.offset) { _, hex in
                        RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(hex: hex)).frame(height: 40)
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.ink.opacity(0.08)))
                            .accessibilityLabel(hex)
                    }
                }
                let tags = style.materials + style.decorItems
                if !tags.isEmpty {
                    FlowLayout(spacing: 6) {
                        ForEach(Array(tags.enumerated()), id: \.offset) { _, tag in
                            Text(tag).font(.forma(11)).foregroundStyle(Theme.wood)
                                .padding(.horizontal, 12).frame(height: 28)
                                .background(Theme.sand, in: Capsule())
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
        } else if model.error == nil {
            HStack(spacing: 10) {
                ProgressView().tint(Theme.sage)
                Text("Reading the vibe…").font(.forma(12)).foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, 24)
        }
    }

    @ViewBuilder private var renderSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Your room, restyled").font(.forma(13, bold: true)).foregroundStyle(Theme.ink).padding(.horizontal, 24)
            if model.isDemo {   // no live render for the saved result: show the room as it is
                Image(uiImage: model.before ?? model.snapshot).resizable().scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .padding(.horizontal, 24)
            } else {
                liveRenderSection
            }
        }
    }

    @ViewBuilder private var liveRenderSection: some View {
        switch model.render {
        case .some(.success(let image)):
            BeforeAfterSlider(before: model.before ?? model.snapshot, after: image).padding(.horizontal, 8)   // + its own 16
        case .some(.failure(let error)):
            errorCard(error.localizedDescription) { await model.rerender() }
        case nil:
            Image(uiImage: model.before ?? model.snapshot).resizable().scaledToFit().blur(radius: 6).opacity(0.6)
                .overlay {
                    HStack(spacing: 10) {
                        ProgressView().tint(Theme.sage)
                        Text("Restyling your room…").font(.forma(12)).foregroundStyle(Theme.ink)
                    }
                    .padding(.horizontal, 18).frame(height: 44)
                    .background(Theme.ground, in: Capsule())
                }
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .padding(.horizontal, 24)
        }
    }

    @ViewBuilder private var shoppingSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Shop the look").font(.forma(13, bold: true)).foregroundStyle(Theme.ink)
                    Spacer()
                    if let rows = model.shopRows, rows.contains(where: { $0.status == .running }) {
                        Text("\(rows.filter { $0.status != .running }.count) of \(rows.count) agents done")
                            .font(.forma(11)).foregroundStyle(Theme.muted)
                    }
                }
                Group {
                    if let budget = model.budgetUSD, !showsSummary {
                        Text("Budget \(usd(budget)).")
                    }
                    Text("Agents browse real stores. Prices exclude shipping and tax.")
                }
                .font(.forma(11)).foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, 24)
            if showsSummary, let budget = model.budgetUSD {
                BudgetSummaryCard(budget: budget, segments: (model.shopRows ?? []).flatMap { row in
                    row.products.filter { model.chosen.contains($0.productURL) }
                        .map { BudgetBar.Segment(id: "\(row.id)-\($0.id)", label: row.query.capitalized, amount: $0.priceUSD ?? 0) }
                }, onChange: { showBudgetSheet = true })
                .padding(.horizontal, 24)
                .transition(sectionTransition)
            }
            addAllButton
            if let error = model.shopError {
                errorCard(error.localizedDescription) { model.retryProducts() }
            }
            ForEach(model.shopRows ?? []) { row in
                shopRow(row).transition(sectionTransition)
            }
        }
        .animation(sectionSpring, value: showsSummary)
        .animation(sectionSpring, value: model.shopRows?.count)
    }

    private var shopFinished: Bool { !(model.shopRows ?? []).contains { $0.status == .running } }
    private var showsSummary: Bool { model.budgetUSD != nil && shopFinished && !model.chosen.isEmpty }

    /// The picks (`chosen`, set once every agent is done) with their row's category, in shopping-list order.
    private var picks: [(product: ShopProduct, category: String)] {
        (model.shopRows ?? []).flatMap { row in
            row.products.filter { model.chosen.contains($0.productURL) }.map { ($0, row.category) }
        }
    }

    /// One tap puts the whole set that fits the budget (or each item's top pick, without one) into the room.
    @ViewBuilder private var addAllButton: some View {
        let all = picks
        if model.projectID != nil, !all.isEmpty {
            let missing = all.filter { !isInRoom($0.product) }
            Button { addToRoom(missing) } label: {
                Label(missing.isEmpty ? "All picks are in your room"
                      : missing.count == all.count ? "Add all \(all.count) picks to room" : "Add the other \(missing.count) picks",
                      systemImage: missing.isEmpty ? "checkmark" : "plus")
            }
            .buttonStyle(PillButtonStyle())
            .disabled(missing.isEmpty)
            .opacity(missing.isEmpty ? 0.4 : 1)
            .accessibilityIdentifier("addAllPicks")
            .keyframeAnimator(initialValue: 1.0, trigger: pulse) { view, scale in view.scaleEffect(scale) } keyframes: { _ in
                KeyframeTrack { SpringKeyframe(1.05, duration: 0.15); SpringKeyframe(1, duration: 0.25) }
            }
            .onAppear { if !reduceMotion { pulse += 1 } }   // once, when the picks arrive
            .padding(.horizontal, 24)
        }
    }

    @ViewBuilder private var flightLayer: some View {
        if let flight {
            GeometryReader { geo in
                let origin = geo.frame(in: .global).origin
                FlyingSquare(imageURL: flight.imageURL,
                             from: flight.from.offsetBy(dx: -origin.x, dy: -origin.y),
                             to: cartFrame.offsetBy(dx: -origin.x, dy: -origin.y))
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .id(flight.id)
        }
    }

    /// Flies the card's photo to the cart button; the cart count only rises on landing so its beam fires then.
    private func addWithFlight(_ product: ShopProduct, row: VibeModel.ShopRow, from: CGRect) {
        guard !reduceMotion, model.projectID != nil else { return addToRoom(product, row: row) }
        landing += 1
        addToRoom(product, row: row)
        Task {
            // First add: the button is only now entering the toolbar, so its frame lands a beat later.
            var waited = 0
            while cartFrame == .zero && waited < 10 { try? await Task.sleep(for: .milliseconds(50)); waited += 1 }
            if cartFrame != .zero {
                flight = Flight(imageURL: product.imageURL, from: from)
                try? await Task.sleep(for: .milliseconds(440))
                flight = nil
            }
            withAnimation(.spring(duration: 0.35, bounce: 0.3)) { landing -= 1 }
        }
    }

    private func shopRow(_ row: VibeModel.ShopRow) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            let products = row.products.isEmpty ? (try? row.quick?.get()) ?? [] : row.products
            HStack(spacing: 8) {
                Text(row.query.capitalized).font(.forma(12, bold: true)).foregroundStyle(Theme.ink).lineLimit(1)
                Spacer(minLength: 8)
                if row.status == .running {
                    ProgressView().controlSize(.small).tint(Theme.sage)
                    Text("Agent shopping…").font(.forma(11)).foregroundStyle(Theme.muted)
                } else if !products.isEmpty {
                    Text(products.count == 1 ? "1 find" : "\(products.count) finds").font(.forma(11)).foregroundStyle(Theme.muted)
                }
            }
            .padding(.horizontal, 24)
            if let budget = model.budgetUSD, shopFinished, !products.isEmpty,
               !products.contains(where: { model.chosen.contains($0.productURL) }) {
                let left = max(budget - (model.totalUSD ?? 0), 0)
                let over = products.filter { ($0.priceUSD ?? 0) > left }.sorted { ($0.priceUSD ?? 0) < ($1.priceUSD ?? 0) }
                if !over.isEmpty {
                    HStack {
                        Text("Nothing fits the \(usd(left)).").font(.forma(11)).foregroundStyle(Theme.terracotta)
                        Spacer()
                        NavigationLink {
                            BudgetOptionsWrapper(row: row, budget: budget, spent: model.totalUSD ?? 0, options: over,
                                                 projectID: model.projectID) { new in changeBudget(new) }
                        } label: {
                            Text("See \(over.count) options").font(.forma(11, bold: true)).foregroundStyle(Theme.ink)
                        }
                    }
                    .padding(.horizontal, 24)
                }
            }
            if !products.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(products) { product in
                            ProductCard(product: product, fitsBudget: model.chosen.contains(product.productURL),
                                        added: isInRoom(product),
                                        projectID: model.projectID, category: row.category,
                                        onAdd: model.projectID == nil ? nil : { addWithFlight(product, row: row, from: $0) })
                        }
                    }
                    .padding(.horizontal, 24)
                }
            } else if row.status == .failed {
                HStack {
                    Text(row.quickFailed ? "Nothing found." : "The agent couldn't find a match.")
                        .font(.forma(11)).foregroundStyle(Theme.muted)
                    Spacer()
                    if row.quick == nil && row.quickLoading {
                        ProgressView().controlSize(.small).tint(Theme.sage)
                    } else {
                        Button("Try quick search") { model.background { await model.quickSearch(row.id) } }
                            .buttonStyle(SmallPillStyle(filled: false))
                    }
                }
                .padding(.horizontal, 24)
            }
        }
        .padding(.top, 14)
        .overlay(alignment: .top) { Theme.hairline.frame(height: 1).padding(.horizontal, 24) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("shopRow-\(row.id)-\(row.category)")
    }

    /// Drops the product into the room as its closest catalog item, sized to the listing when it gives dimensions.
    private func addToRoom(_ product: ShopProduct, row: VibeModel.ShopRow) {
        addToRoom([(product, row.category)])
    }

    private func addToRoom(_ picks: [(product: ShopProduct, category: String)]) {
        guard let id = model.projectID else { return }
        RoomCart.add(picks, to: id, store: store)
    }

    /// Read from the project, so it survives leaving and reopening this screen.
    private func isInRoom(_ product: ShopProduct) -> Bool {
        RoomCart.contains(product, in: store.projects.first { $0.id == model.projectID })
    }

    @ViewBuilder private var productsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Shop the look").font(.forma(13, bold: true)).foregroundStyle(Theme.ink).padding(.horizontal, 24)
            switch model.products {
            case .some(.success(let products)) where products.isEmpty:
                Text("No products found.").font(.forma(11)).foregroundStyle(Theme.muted).padding(.horizontal, 24)
            case .some(.success(let products)):
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(products) { ProductCard(product: $0, category: $0.category ?? "") }
                    }
                    .padding(.horizontal, 24)
                }
            case .some(.failure(let error)):
                errorCard(error.localizedDescription) { model.retryProducts() }
            case nil:
                ProgressView().tint(Theme.sage).frame(maxWidth: .infinity)
            }
        }
    }

    private func errorCard(_ message: String, retry: (() async -> Void)? = nil) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "exclamationmark.circle").font(.system(size: 15)).foregroundStyle(Theme.terracotta)
            Text(message).font(.forma(12)).foregroundStyle(Theme.ink)
            Spacer(minLength: 8)
            if let retry { Button("Retry") { Task { await retry() } }.buttonStyle(SmallPillStyle(filled: false)) }
        }
        .padding(16)
        .background(Theme.sand, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.terracotta.opacity(0.35)))
        .padding(.horizontal, 24)
    }
}

/// Pops back after either choice.
private struct BudgetOptionsWrapper: View {
    @Environment(\.dismiss) private var dismiss
    let row: VibeModel.ShopRow
    let budget: Double
    let spent: Double
    let options: [ShopProduct]
    let projectID: UUID?
    let onRaise: (Double) -> Void

    var body: some View {
        BudgetOptionsView(itemName: row.query.capitalized, category: row.category, projectID: projectID,
                          budget: budget, spent: spent, options: options,
                          onRaise: { onRaise($0); dismiss() }, onSkip: { dismiss() })
    }
}

/// Compact pill for row-level actions (Retry, Add, Open, Try quick search): sage filled, or a 1 pt ink outline.
private struct SmallPillStyle: ButtonStyle {
    var filled = true
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.forma(12, bold: true))
            .lineLimit(1)
            .foregroundStyle(filled ? Theme.onSage : Theme.ink)
            .padding(.horizontal, 14)
            .frame(minHeight: 34)
            .background(filled ? Theme.sage : .clear, in: Capsule())
            .overlay { if !filled { Capsule().strokeBorder(Theme.ink, lineWidth: 1) } }
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.45)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(duration: 0.2, bounce: 0), value: configuration.isPressed)
            .padding(.vertical, 5)   // 34 pt pill, 44 pt hit target
            .contentShape(Rectangle())
    }
}

/// Paper "Add to cart" motion: x eases out, y eases in, so the square arcs into the cart while it shrinks and fades.
private struct FlyingSquare: View {
    let imageURL: URL?
    let from: CGRect
    let to: CGRect
    @State private var x = false
    @State private var y = false

    var body: some View {
        AsyncImage(url: imageURL) { phase in
            if case .success(let image) = phase { image.resizable().scaledToFill() } else { Theme.sand }
        }
        .frame(width: 56, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .scaleEffect(y ? 0.25 : 1)
        .opacity(y ? 0.2 : 1)
        .position(x: x ? to.midX : from.midX, y: y ? to.midY : from.midY)
        .onAppear {
            withAnimation(.easeOut(duration: 0.44)) { x = true }
            withAnimation(.easeIn(duration: 0.44)) { y = true }
        }
    }
}

private struct ProductCard: View {
    let product: ShopProduct
    var fitsBudget = false
    var added = false
    var projectID: UUID? = nil
    var category = ""
    /// Gets the photo's global frame, where the add-to-cart square lifts off.
    var onAdd: ((CGRect) -> Void)? = nil
    @State private var imageFrame: CGRect = .zero
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AsyncImage(url: product.imageURL) { phase in
                switch phase {
                case .success(let image): image.resizable().scaledToFill()
                case .failure: Image(systemName: "photo").font(.system(size: 20)).foregroundStyle(Theme.muted)
                        .frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.sand)
                default: Theme.sand
                }
            }
            .frame(width: 156, height: 156)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.hairline))
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { imageFrame = $0 }
            .overlay(alignment: .topLeading) {
                if fitsBudget {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).accessibilityHidden(true)
                        Text("Fits budget").font(.forma(10, bold: true))
                    }
                    .foregroundStyle(Theme.onSage)
                    .padding(.horizontal, 8).frame(height: 22)
                    .background(Theme.sage, in: Capsule())
                    .padding(8)
                }
            }
            Text(product.title).font(.forma(11)).foregroundStyle(Theme.ink).lineLimit(2, reservesSpace: true)
            HStack(alignment: .firstTextBaseline) {
                Text(product.price).font(.forma(13, bold: true)).foregroundStyle(Theme.ink)
                Spacer(minLength: 6)
                Text(product.retailer).font(.forma(10)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            HStack(spacing: 6) {
                if let onAdd {
                    Button { onAdd(imageFrame) } label: {
                        ZStack {
                            Text("Add").opacity(added ? 0 : 1)
                            Text("Added").opacity(added ? 1 : 0)
                        }
                        .frame(maxWidth: .infinity)
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: added)
                    }
                        .buttonStyle(SmallPillStyle())
                        .disabled(added)
                        .accessibilityLabel(added ? "Added to room" : "Add to room")
                }
                NavigationLink {
                    ProductDetailView(product: product, mode: .shopping(projectID: projectID, category: category))
                } label: { Text("Open").frame(maxWidth: .infinity) }
                    .buttonStyle(SmallPillStyle(filled: false))
                    .accessibilityLabel("Open \(product.title)")
            }
        }
        .frame(width: 156)
    }
}

@Observable
@MainActor
final class VibeModel {
    /// The Designer view a new run restyles. A reopened room run gets the latest view here.
    private(set) var snapshot: UIImage
    /// The view the current restyle was made from (shown as "Before").
    private(set) var before: UIImage?
    let projectID: UUID?
    /// When a restored run was saved; nil for a run made in this session.
    private(set) var savedAt: Date?
    private(set) var inspiration: UIImage?
    private(set) var prompt = ""
    private(set) var started = false
    private(set) var style: VibeStyle?
    private(set) var render: Result<UIImage, Error>?
    /// Quick search results, used when the backend's style has no shopping list.
    private(set) var products: Result<[ShopProduct], Error>?
    /// Shopping agents: one row per shopping-list item, filled in as each agent finishes.
    private(set) var shopRows: [ShopRow]?
    private(set) var shopError: Error?
    private(set) var chosen: Set<URL> = []
    private(set) var budgetUSD: Double?
    private(set) var totalUSD: Double?
    private(set) var error: String?
    /// Showing the bundled demo result (VibeDemo) instead of a live run.
    private(set) var isDemo = false

    struct ShopRow: Identifiable {
        let id: Int
        var category: String
        var query: String
        var status: ShopStatus.Item.Status = .running
        var products: [ShopProduct] = []
        /// The server's cap for this item (`cap_usd`); nil until a status arrives or on older servers.
        var capUsd: Double?
        var quick: Result<[ShopProduct], Error>?
        var quickLoading = false
        var quickFailed: Bool { if case .some(.success(let p)) = quick { p.isEmpty } else { false } }
    }

    /// The backend's MAX_PROMPT.
    static let maxPrompt = 1000
    private static let pollInterval: Duration = .seconds(4)
    private static let maxPollFailures = 3
    private static let shopDeadline: Duration = .seconds(8 * 60)   // the backend gives up on an agent after 6 min

    /// The current pick's run. A newer pick cancels it so its results can't land under the new photo.
    private var run: Task<Void, Never>?
    /// The shopping agents' job token (stateless on the backend), kept so polling can resume after a relaunch.
    private var job: String?
    private var shopDone = false
    /// Budget the user typed into the field; beats the one the backend parsed from the prompt.
    var budgetOverride: Double?
    /// The budget once the run has settled, nil before (and for a run without one). The screen saves it to the room.
    var settledBudget: Double? { shopDone && !isDemo ? budgetUSD : nil }
    private var poller: Task<Void, Never>?
    /// The current restyle is already on disk.
    private var renderWritten = false
    /// Layout, structure map and view for `snapshot` (set with it), so the restyle can't invent walls or floors.
    @ObservationIgnored private var grounding: (() async -> RenderGrounding)?

    /// One model per room for the app's lifetime, so leaving Shop a vibe doesn't stop the restyle or the agents.
    /// A room seen for the first time this launch starts from its saved run, if any.
    private static var rooms: [UUID: VibeModel] = [:]

    static func forRoom(_ projectID: UUID?, snapshot: UIImage, grounding: (() async -> RenderGrounding)? = nil) -> VibeModel {
        guard let projectID else {
            let model = VibeModel(snapshot: snapshot, projectID: nil)
            model.grounding = grounding
            return model
        }
        if let model = rooms[projectID] {
            model.snapshot = snapshot.croppedToRenderAspect()
            model.grounding = grounding
            return model
        }
        let model = VibeModel(snapshot: snapshot, projectID: projectID)
        model.grounding = grounding
        model.restore()
        rooms[projectID] = model
        return model
    }
    /// Retries and quick searches started from buttons, cancelled with `run` when the screen goes away.
    private var side: [Task<Void, Never>] = []

    init(snapshot: UIImage, projectID: UUID?) {
        self.snapshot = snapshot.croppedToRenderAspect()
        self.projectID = projectID
    }

    func begin(with image: UIImage?, prompt: String) {
        run?.cancel()
        run = Task { await start(with: image, prompt: prompt) }
    }

    func retryAnalyze() {
        if started { begin(with: inspiration, prompt: prompt) }
    }

    func cancel() {
        run?.cancel()
        poller?.cancel()
        side.forEach { $0.cancel() }
        side.removeAll()
    }

    func background(_ work: @escaping @MainActor () async -> Void) {
        side.removeAll { $0.isCancelled }
        side.append(Task { await work() })
    }

    /// Resumes an unfinished agent job instead of paying for new agents; otherwise searches again.
    func retryProducts() {
        if let job, let style, !shopDone {
            shopError = nil
            resume(job, style)
        } else {
            background { await self.reloadProducts() }
        }
    }

    func fail(_ message: String) { error = message }

    /// Shows a recorded run as if it had just finished. Used when the backend can't be reached on stage.
    func showDemo(_ demo: VibeDemo) {
        run?.cancel()
        side.forEach { $0.cancel() }
        side.removeAll()
        inspiration = nil
        prompt = demo.prompt
        started = true
        isDemo = true
        error = nil
        render = nil
        style = demo.style
        resetShopping()
        shopRows = demo.status.items.enumerated().map { ShopRow(id: $0.offset, category: $0.element.category,
                                                                 query: $0.element.query) }
        apply(demo.status)
    }

    /// Network trouble that the bundled demo result should cover for. Bad input (4xx) still shows its error.
    private func fallBackToDemo(after error: Error) -> Bool {
        switch error as? APIError {
        case .offline, .timeout: break
        case .server(let code, _) where code >= 500: break
        default: return false
        }
        guard let demo = VibeDemo.load() else { return false }
        showDemo(demo)
        return true
    }

    private func start(with image: UIImage?, prompt: String) async {
        inspiration = image
        self.prompt = prompt
        started = true
        isDemo = false
        savedAt = nil
        style = nil; render = nil; error = nil
        resetShopping()
        do {
            let analyzed = try await APIClient.shared.analyzeVibe(image, prompt: prompt)
            guard !Task.isCancelled else { return }
            style = analyzed
            save()
        } catch {
            if !Task.isCancelled && !(error is CancellationError) && !fallBackToDemo(after: error) {
                self.error = error.localizedDescription
            }
            return
        }
        async let r: Void = rerender()
        async let p: Void = reloadProducts()
        _ = await (r, p)
    }

    func rerender() async {
        guard let style else { return }
        render = nil
        renderWritten = false
        before = snapshot
        let result: Result<UIImage, Error>
        do {
            let g = await grounding?()
            result = .success(try await APIClient.shared.render(snapshot, prompt: style.renderPrompt, layout: g?.layout ?? "",
                                                                view: g?.view ?? "cutaway", structure: g?.structure,
                                                                styleRef: inspiration, products: g?.products ?? []))
        } catch {
            result = .failure(error)
        }
        if !Task.isCancelled, style == self.style {
            render = result
            save()
        }
    }

    func reloadProducts() async {
        guard let style else { return }
        if let list = style.shoppingList, !list.isEmpty {
            await shop(style)
            return
        }
        resetShopping()
        let result: Result<[ShopProduct], Error>
        do { result = .success(try await APIClient.shared.products(for: style)) } catch { result = .failure(error) }
        if !Task.isCancelled, style == self.style { products = result }
    }

    private func resetShopping() {
        poller?.cancel()
        products = nil; shopRows = nil; shopError = nil; chosen = []; budgetUSD = nil; totalUSD = nil
        job = nil; shopDone = false
    }

    /// Starts the agents, then polls until every item has finished. Rows fill in as their agent finishes.
    private func shop(_ style: VibeStyle) async {
        resetShopping()
        shopRows = (style.shoppingList ?? []).enumerated().map { ShopRow(id: $0.offset, category: $0.element.category,
                                                                          query: $0.element.query) }
        budgetUSD = budgetOverride ?? style.budgetUsd
        do {
            let started = try await APIClient.shared.startShopping(style, budget: budgetOverride)
            guard !Task.isCancelled, style == self.style else { return }
            job = started.job
            save()
        } catch {
            shopFailed(error, style)
            return
        }
        resume(job!, style)
        await poller?.value
    }

    /// Polls `job` in its own task, so it outlives the screen and can restart after a relaunch.
    private func resume(_ job: String, _ style: VibeStyle) {
        poller?.cancel()
        poller = Task { await poll(job, style) }
    }

    private func poll(_ job: String, _ style: VibeStyle) async {
        do {
            var failures = 0
            let deadline = ContinuousClock.now + Self.shopDeadline
            while !Task.isCancelled, style == self.style {
                if ContinuousClock.now > deadline { throw APIError.timeout }
                let status: ShopStatus
                do {
                    status = try await APIClient.shared.pollShopping(ShopJob(job: job, items: []))
                    failures = 0
                } catch let error as APIError {
                    // A dropped poll is fine; the agents keep running server side. Give up after a few in a row.
                    failures += 1
                    if failures >= Self.maxPollFailures { throw error }
                    try await Task.sleep(for: Self.pollInterval)
                    continue
                }
                guard !Task.isCancelled, style == self.style else { return }
                apply(status)
                shopDone = status.done
                save()
                if status.done { return }
                try await Task.sleep(for: Self.pollInterval)
            }
        } catch {
            shopFailed(error, style)
        }
    }

    private func shopFailed(_ error: Error, _ style: VibeStyle) {
        guard !Task.isCancelled, !(error is CancellationError), style == self.style, !isDemo,
              !fallBackToDemo(after: error) else { return }
        shopError = error
        if var rows = shopRows {   // no spinners left behind the error
            for i in rows.indices where rows[i].status == .running { rows[i].status = .failed }
            shopRows = rows
        }
    }

    // MARK: Saved run (Projects/<id>/vibe-latest.*): one per room, replaced by the next run

    private struct Saved: Codable {
        var prompt: String
        var style: VibeStyle
        var job: String?
        var done: Bool
        var rows: [Row]
        var chosen: [URL]
        var budgetUSD: Double?
        var totalUSD: Double?
        struct Row: Codable {
            var category: String
            var query: String
            var status: ShopStatus.Item.Status
            var products: [ShopProduct]
            var capUsd: Double?   // optional so older saves still decode
        }
    }

    private func file(_ ext: String) -> URL? {
        projectID.map { ProjectStore.projectDir($0).appending(path: "vibe-latest.\(ext)") }
    }

    private func save() {
        guard !isDemo, let style, let json = file("json"), let image = file("jpg"), let beforeURL = file("before.jpg") else { return }
        let saved = Saved(prompt: prompt, style: style, job: job, done: shopDone,
                          rows: (shopRows ?? []).map { .init(category: $0.category, query: $0.query, status: $0.status,
                                                             products: $0.products, capUsd: $0.capUsd) },
                          chosen: Array(chosen), budgetUSD: budgetUSD, totalUSD: totalUSD)
        try? FileManager.default.createDirectory(at: json.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(saved).write(to: json, options: .atomic)
        if case .success(let rendered) = render {
            if !renderWritten {
                try? rendered.jpegData(compressionQuality: 0.9)?.write(to: image, options: .atomic)
                try? before?.jpegData(compressionQuality: 0.8)?.write(to: beforeURL, options: .atomic)
                renderWritten = true
            }
        } else {   // a new run: the old restyle no longer matches
            try? FileManager.default.removeItem(at: image)
            try? FileManager.default.removeItem(at: beforeURL)
        }
    }

    /// Shows the room's last run and picks up whatever it hadn't finished: the restyle, or the agents' polling.
    private func restore() {
        guard let json = file("json"), let data = try? Data(contentsOf: json),
              let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        prompt = saved.prompt
        style = saved.style
        started = true
        savedAt = (try? FileManager.default.attributesOfItem(atPath: json.path(percentEncoded: false)))?[.modificationDate] as? Date
        if let image = file("jpg").flatMap({ try? Data(contentsOf: $0) }).flatMap(UIImage.init(data:)) {
            render = .success(image)
            renderWritten = true
            before = file("before.jpg").flatMap { try? Data(contentsOf: $0) }.flatMap(UIImage.init(data:))
        } else {
            background { await self.rerender() }
        }
        budgetUSD = saved.budgetUSD
        totalUSD = saved.totalUSD
        chosen = Set(saved.chosen)
        job = saved.job
        shopDone = saved.done
        if saved.rows.isEmpty {
            if saved.job == nil { background { await self.reloadProducts() } }
        } else {
            shopRows = saved.rows.enumerated().map {
                ShopRow(id: $0.offset, category: $0.element.category, query: $0.element.query, status: $0.element.status,
                        products: $0.element.products, capUsd: $0.element.capUsd)
            }
        }
        if let job, !shopDone { resume(job, saved.style) }
    }

    private func apply(_ status: ShopStatus) {
        guard var rows = shopRows else { return }
        for (i, item) in status.items.enumerated() where i < rows.count {
            rows[i].status = item.status
            rows[i].products = item.products
            rows[i].capUsd = item.capUsd
        }
        shopRows = rows
        budgetUSD = status.budgetUsd
        chosen = Set(status.chosen ?? [])
        totalUSD = status.totalUsd
    }

    /// Re-picks the set under a new budget (nil = no limit) from the products already found.
    func applyBudget(_ usd: Double?) async {
        guard let job, let status = try? await APIClient.shared.pollShopping(ShopJob(job: job, items: []),
                                                                             budget: usd, noLimit: usd == nil) else { return }
        apply(status)
        budgetUSD = usd == nil ? nil : status.budgetUsd ?? usd
        save()
    }

    /// Quick search (/vibe/products) for one item whose agent came back empty.
    func quickSearch(_ id: Int) async {
        guard var style, let row = shopRows?.first(where: { $0.id == id }) else { return }
        let current = style
        style.searchQueries = [row.query]
        update(id) { $0.quickLoading = true; $0.quick = nil }
        let result: Result<[ShopProduct], Error>
        do { result = .success(try await APIClient.shared.products(for: style)) } catch { result = .failure(error) }
        guard current == self.style else { return }
        update(id) {
            $0.quickLoading = false
            $0.quick = result
            // The server's (rescaled) cap; the parsed one only if the server sent none.
            if case .success(let p) = result,
               let cap = row.capUsd ?? current.shoppingList?.first(where: { $0.query == row.query })?.maxPriceUsd {
                // Keep only what provably fits that item's share of the budget.
                $0.quick = .success(p.filter { ($0.priceUSD ?? dollars($0.price)).map { $0 <= cap } ?? false })
            }
        }
    }

    private func update(_ id: Int, _ change: (inout ShopRow) -> Void) {
        guard let i = shopRows?.firstIndex(where: { $0.id == id }) else { return }
        change(&shopRows![i])
    }
}

/// The first "$1,299.00"-style amount -> 1299; nil if there is none. Quick search prices are display text only.
private func dollars(_ text: String) -> Double? {
    // One plain amount only: "$10.99/mo, $1,200 total" or "Save $50 on $800" is not a price we can trust.
    let amounts = text.matches(of: /\$\s?([\d,]+(?:\.\d+)?)/)
    guard amounts.count == 1, !text.localizedCaseInsensitiveContains("/mo") else { return nil }
    return Double(amounts[0].1.filter { $0 != "," })
}

private func usd(_ value: Double) -> String {
    value.formatted(.currency(code: "USD").precision(.fractionLength(value.rounded() == value ? 0 : 2)))
}

/// Decodes a picked photo at <= 2048 px, so a 48 MP HEIC doesn't stall the UI or the upload resize.
private func downsampled(_ data: Data, maxPixel: Int = 2048) -> UIImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
              kCGImageSourceCreateThumbnailFromImageAlways: true,
              kCGImageSourceCreateThumbnailWithTransform: true,
              kCGImageSourceThumbnailMaxPixelSize: maxPixel,
          ] as CFDictionary) else { return nil }
    return UIImage(cgImage: image)
}

private extension Color {
    /// "#RRGGBB" -> Color; anything else -> gray.
    init(hex: String) {
        let v = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0x808080
        self.init(red: Double(v >> 16 & 0xFF) / 255, green: Double(v >> 8 & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

extension Placement {
    /// A catalog stand-in for a shopped product: the matching CatalogItem (or a Custom Box), scaled to the listing's
    /// width/height/depth when it has them, at the room's center (the scene origin: RoomBuilder centers the room).
    /// The Designer moves it to the nearest free floor spot and keeps it inside the walls.
    static func forProduct(_ product: ShopProduct, category: String) -> Placement {
        let item = CatalogItem.item(category) ?? CatalogItem.item("custom_box")!
        var p = Placement(id: UUID(), objectID: Placement.catalogObjectID, position: .zero, yRotation: 0,
                          catalogItem: item.id, product: product)
        if let cm = product.dimensionsCm, cm.count == 3, cm.allSatisfy({ $0 > 0 && $0.isFinite }) {
            let scale = SIMD3(Float(cm[0]), Float(cm[1]), Float(cm[2])) / 100 / item.size
            p.scale = simd_clamp(scale, SIMD3(repeating: 0.05), SIMD3(repeating: 6))   // the Size editor's range
            p.fitScale = p.scale
        }
        return p
    }
}

/// A recorded Vibe run bundled with the app (DemoData/vibe_demo.json, written by scripts/record_vibe_demo.py).
/// Product images are "bundle:<file>" and resolve to bundled JPEGs, so the demo works offline.
struct VibeDemo: Decodable {
    var prompt: String
    var style: VibeStyle
    var status: ShopStatus

    static func load(bundle: Bundle = .main) -> VibeDemo? {
        guard let url = bundle.url(forResource: "vibe_demo", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard var demo = try? decoder.decode(VibeDemo.self, from: data) else { return nil }
        for i in demo.status.items.indices {
            for j in demo.status.items[i].products.indices {
                let product = demo.status.items[i].products[j]
                if let image = product.imageURL, image.scheme == "bundle" {
                    let file = image.absoluteString.dropFirst("bundle:".count)
                    demo.status.items[i].products[j].imageURL = bundle.url(forResource: String(file.prefix { $0 != "." }),
                                                                           withExtension: "jpg")
                }
            }
        }
        return demo
    }
}
