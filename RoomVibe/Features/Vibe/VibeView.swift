import ImageIO
import PhotosUI
import SwiftUI

/// Vibe mode: an inspiration photo and/or a description -> /vibe/analyze -> restyled render (/render with the style
/// and the photo as reference) + real products found by shopping agents (/vibe/shop), within the budget if one was
/// given. Falls back to quick search (/vibe/products) per item. Pushed from RenderView's navigation stack.
struct VibeView: View {
    @Environment(ProjectStore.self) private var store
    @State private var model: VibeModel
    @State private var pick: PhotosPickerItem?
    @State private var photo: UIImage?
    @State private var prompt = ""
    @FocusState private var promptFocused: Bool
    private let preset: UIImage?

    /// `inspiration`: optional preset photo (e.g. a bundled demo image) that starts the flow immediately.
    init(snapshot: UIImage, projectID: UUID? = nil, inspiration: UIImage? = nil) {
        _model = State(initialValue: VibeModel(snapshot: snapshot, projectID: projectID))
        preset = inspiration
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                input
                if let error = model.error { errorCard(error) { model.retryAnalyze() } }
                if model.started { styleSection }
                if model.style != nil {
                    renderSection
                    if model.shopRows != nil || model.shopError != nil { shoppingSection } else { productsSection }
                }
            }
            .padding(.vertical)
        }
        .navigationTitle("Vibe")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .onAppear {
            if let preset, !model.started {
                photo = preset
                model.begin(with: preset, prompt: "")
            }
        }
        .onDisappear { model.cancel() }
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

    private var canStart: Bool { photo != nil || !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var input: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                PhotosPicker(selection: $pick, matching: .images) {
                    Group {
                        if let photo {
                            Image(uiImage: photo).resizable().scaledToFill()
                        } else {
                            Image(systemName: "photo.badge.plus").font(.title2)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(.quaternary)
                        }
                    }
                    .frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .accessibilityLabel(photo == nil ? "Add an inspiration photo" : "Change the inspiration photo")
                VStack(alignment: .leading, spacing: 2) {
                    Text("Describe a vibe, add a photo, or both").font(.headline)
                        // Hidden stage trigger (kept in Release): long-press the title on a fresh screen to show the
                        // bundled demo result.
                        .onLongPressGesture(minimumDuration: 0.8) {
                            if !model.started, let demo = VibeDemo.load() { prompt = demo.prompt; model.showDemo(demo) }
                        }
                    Text("We'll restyle your room and send agents to shop for real pieces.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if photo != nil {
                    Button { photo = nil } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Remove photo")
                }
            }
            TextField("Cozy reading nook, warm wood, under $800", text: $prompt, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
                .focused($promptFocused)
                .submitLabel(.go)
                .onSubmit(start)
                .accessibilityIdentifier("vibePrompt")
            Button(action: start) {
                Label(model.started ? "Find a new vibe" : "Find my vibe", systemImage: "sparkles").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canStart)
            .accessibilityIdentifier("vibeStart")
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
    }

    private func start() {
        guard canStart else { return }
        promptFocused = false
        model.begin(with: photo, prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @ViewBuilder private var styleSection: some View {
        if let style = model.style {
            VStack(alignment: .leading, spacing: 8) {
                Text(style.styleName).font(.title2.bold())
                if model.isDemo {
                    Text("Saved demo result").font(.caption2).foregroundStyle(.tertiary)
                }
                HStack(spacing: 6) {
                    ForEach(Array(style.palette.enumerated()), id: \.offset) { _, hex in
                        Circle().fill(Color(hex: hex)).frame(width: 28, height: 28)
                            .overlay(Circle().stroke(.separator))
                            .accessibilityLabel(hex)
                    }
                }
                Text((style.materials + style.decorItems).joined(separator: " · "))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .padding(.horizontal)
        } else if model.error == nil {
            Label("Reading the vibe…", systemImage: "sparkles").padding(.horizontal)
                .symbolEffect(.pulse)
        }
    }

    @ViewBuilder private var renderSection: some View {
        if model.isDemo {   // no live render for the saved result: show the room as it is
            Image(uiImage: model.snapshot).resizable().scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal)
        } else {
            liveRenderSection
        }
    }

    @ViewBuilder private var liveRenderSection: some View {
        switch model.render {
        case .some(.success(let image)):
            BeforeAfterSlider(before: model.snapshot, after: image)
        case .some(.failure(let error)):
            errorCard(error.localizedDescription) { await model.rerender() }
        case nil:
            Image(uiImage: model.snapshot).resizable().scaledToFit().blur(radius: 6).opacity(0.6)
                .overlay { ProgressView("Restyling your room…").padding().background(.regularMaterial, in: Capsule()) }
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal)
        }
    }

    @ViewBuilder private var shoppingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Shop the look").font(.headline)
                if let budget = model.budgetUSD {
                    if let total = model.totalUSD, !model.chosen.isEmpty {
                        Text("Picks marked \"Fits budget\" total \(usd(total)) of your \(usd(budget)).")
                    } else {
                        Text("Budget \(usd(budget)).")
                    }
                }
                Text("Agents browse real stores. Prices exclude shipping and tax.")
            }
            .font(.footnote).foregroundStyle(.secondary)
            .padding(.horizontal)
            addAllButton
            if let error = model.shopError {
                errorCard(error.localizedDescription) { model.retryProducts() }
            }
            ForEach(model.shopRows ?? []) { row in
                shopRow(row)
            }
        }
    }

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
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(missing.isEmpty)
            .accessibilityIdentifier("addAllPicks")
            .padding(.horizontal)
        }
    }

    private func shopRow(_ row: VibeModel.ShopRow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(row.query.capitalized).font(.subheadline.bold())
                if row.status == .running { ProgressView().controlSize(.small) }
                Spacer()
                if row.status == .running {
                    Text("Agent shopping…").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal)
            let products = row.products.isEmpty ? (try? row.quick?.get()) ?? [] : row.products
            if !products.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(products) { product in
                            ProductCard(product: product, fitsBudget: model.chosen.contains(product.productURL),
                                        added: isInRoom(product),
                                        onAdd: model.projectID == nil ? nil : { addToRoom(product, row: row) })
                        }
                    }
                    .padding(.horizontal)
                }
            } else if row.status == .failed {
                HStack {
                    Text(row.quickFailed ? "Nothing found." : "The agent couldn't find a match.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Spacer()
                    if row.quick == nil && row.quickLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Try quick search") { model.background { await model.quickSearch(row.id) } }
                            .buttonStyle(.bordered).controlSize(.small)
                    }
                }
                .padding(.horizontal)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("shopRow-\(row.id)-\(row.category)")
    }

    /// Drops the product into the room as its closest catalog item, sized to the listing when it gives dimensions.
    private func addToRoom(_ product: ShopProduct, row: VibeModel.ShopRow) {
        addToRoom([(product, row.category)])
    }

    /// In one store update, so the Designer underneath spawns them together and spreads them over free floor.
    private func addToRoom(_ picks: [(product: ShopProduct, category: String)]) {
        guard let id = model.projectID, var project = store.projects.first(where: { $0.id == id }) else { return }
        for pick in picks where !project.placements.contains(where: { $0.product?.productURL == pick.product.productURL }) {
            project.placements.append(Placement.forProduct(pick.product, category: pick.product.category ?? pick.category))
        }
        store.update(project)
    }

    /// Read from the project, so it survives leaving and reopening this screen.
    private func isInRoom(_ product: ShopProduct) -> Bool {
        store.projects.first { $0.id == model.projectID }?.placements
            .contains { $0.product?.productURL == product.productURL } ?? false
    }

    @ViewBuilder private var productsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Shop the look").font(.headline).padding(.horizontal)
            switch model.products {
            case .some(.success(let products)) where products.isEmpty:
                Text("No products found.").font(.footnote).foregroundStyle(.secondary).padding(.horizontal)
            case .some(.success(let products)):
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(products) { ProductCard(product: $0) }
                    }
                    .padding(.horizontal)
                }
            case .some(.failure(let error)):
                errorCard(error.localizedDescription) { model.retryProducts() }
            case nil:
                ProgressView().frame(maxWidth: .infinity)
            }
        }
    }

    private func errorCard(_ message: String, retry: (() async -> Void)? = nil) -> some View {
        HStack {
            Label(message, systemImage: "exclamationmark.triangle").font(.footnote)
            Spacer()
            if let retry { Button("Retry") { Task { await retry() } }.buttonStyle(.bordered) }
        }
        .padding(12)
        .background(.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
    }
}

private struct ProductCard: View {
    let product: ShopProduct
    var fitsBudget = false
    var added = false
    var onAdd: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            AsyncImage(url: product.imageURL) { phase in
                switch phase {
                case .success(let image): image.resizable().scaledToFill()
                case .failure: Image(systemName: "photo").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.secondary.opacity(0.15))
                default: Color.secondary.opacity(0.15)
                }
            }
            .frame(width: 150, height: 150)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(alignment: .topLeading) {
                if fitsBudget {
                    Label("Fits budget", systemImage: "checkmark.seal.fill").font(.caption2.bold())
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(.green, in: Capsule()).foregroundStyle(.white)
                        .padding(6)
                }
            }
            Text(product.title).font(.subheadline).lineLimit(2, reservesSpace: true)
            HStack {
                Text(product.price).font(.subheadline.bold())
                Spacer()
                Text(product.retailer).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            HStack(spacing: 6) {
                if let onAdd {
                    Button(action: onAdd) {
                        Label(added ? "Added" : "Add", systemImage: added ? "checkmark" : "plus").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(added)
                    .accessibilityLabel(added ? "Added to room" : "Add to room")
                }
                Link(destination: product.productURL) {
                    Label("Open", systemImage: "arrow.up.right.square").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .labelStyle(.titleOnly)
            .controlSize(.small)
        }
        .frame(width: 150)
    }
}

@Observable
@MainActor
final class VibeModel {
    let snapshot: UIImage
    let projectID: UUID?
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
        var quick: Result<[ShopProduct], Error>?
        var quickLoading = false
        var quickFailed: Bool { if case .some(.success(let p)) = quick { p.isEmpty } else { false } }
    }

    private static let pollInterval: Duration = .seconds(4)
    private static let maxPollFailures = 3
    private static let shopDeadline: Duration = .seconds(8 * 60)   // the backend gives up on an agent after 6 min

    /// The current pick's run. A newer pick cancels it so its results can't land under the new photo.
    private var run: Task<Void, Never>?
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
        side.forEach { $0.cancel() }
        side.removeAll()
    }

    func background(_ work: @escaping @MainActor () async -> Void) {
        side.removeAll { $0.isCancelled }
        side.append(Task { await work() })
    }

    func retryProducts() { background { await self.reloadProducts() } }

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
        style = nil; render = nil; error = nil
        resetShopping()
        do {
            let analyzed = try await APIClient.shared.analyzeVibe(image, prompt: prompt)
            guard !Task.isCancelled else { return }
            style = analyzed
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
        let result: Result<UIImage, Error>
        do {
            result = .success(try await APIClient.shared.render(snapshot, prompt: style.renderPrompt, styleRef: inspiration))
        } catch {
            result = .failure(error)
        }
        if !Task.isCancelled, style == self.style { render = result }
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
        products = nil; shopRows = nil; shopError = nil; chosen = []; budgetUSD = nil; totalUSD = nil
    }

    /// Starts the agents, then polls until every item has finished. Rows fill in as their agent finishes.
    private func shop(_ style: VibeStyle) async {
        resetShopping()
        shopRows = (style.shoppingList ?? []).enumerated().map { ShopRow(id: $0.offset, category: $0.element.category,
                                                                          query: $0.element.query) }
        budgetUSD = style.budgetUsd
        do {
            let job = try await APIClient.shared.startShopping(style)
            var failures = 0
            let deadline = ContinuousClock.now + Self.shopDeadline
            while !Task.isCancelled, style == self.style {
                if ContinuousClock.now > deadline { throw APIError.timeout }
                let status: ShopStatus
                do {
                    status = try await APIClient.shared.pollShopping(job)
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
                if status.done { return }
                try await Task.sleep(for: Self.pollInterval)
            }
        } catch {
            if !Task.isCancelled && !(error is CancellationError), style == self.style, !isDemo,
               !fallBackToDemo(after: error) {
                shopError = error
                if var rows = shopRows {   // no spinners left behind the error
                    for i in rows.indices where rows[i].status == .running { rows[i].status = .failed }
                    shopRows = rows
                }
            }
        }
    }

    private func apply(_ status: ShopStatus) {
        guard var rows = shopRows else { return }
        for (i, item) in status.items.enumerated() where i < rows.count {
            rows[i].status = item.status
            rows[i].products = item.products
        }
        shopRows = rows
        budgetUSD = status.budgetUsd
        chosen = Set(status.chosen ?? [])
        totalUSD = status.totalUsd
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
            if case .success(let p) = result, let cap = current.shoppingList?.first(where: { $0.query == row.query })?.maxPriceUsd {
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
