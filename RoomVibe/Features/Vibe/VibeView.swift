import ImageIO
import PhotosUI
import SwiftUI

/// Vibe mode: pick an inspiration photo -> /vibe/analyze -> restyled render (/render with the style and the
/// photo as reference) + shoppable products (/vibe/products). Pushed from RenderView's navigation stack.
struct VibeView: View {
    @State private var model: VibeModel
    @State private var pick: PhotosPickerItem?
    private let preset: UIImage?

    /// `inspiration`: optional preset photo (e.g. a bundled demo image) that starts the flow immediately.
    init(snapshot: UIImage, projectID: UUID? = nil, inspiration: UIImage? = nil) {
        _model = State(initialValue: VibeModel(snapshot: snapshot, projectID: projectID))
        preset = inspiration
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                picker
                if let error = model.error { errorCard(error) { model.retryAnalyze() } }
                if model.inspiration != nil { styleSection }
                if model.style != nil {
                    renderSection
                    productsSection
                }
            }
            .padding(.vertical)
        }
        .navigationTitle("Vibe")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if let preset, model.inspiration == nil { model.begin(with: preset) } }
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
                    model.begin(with: image)
                } catch {
                    model.fail("Couldn't open that photo. Try another one.")
                }
            }
        }
    }

    private var picker: some View {
        PhotosPicker(selection: $pick, matching: .images) {
            HStack(spacing: 12) {
                if let inspiration = model.inspiration {
                    Image(uiImage: inspiration).resizable().scaledToFill()
                        .frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    Image(systemName: "photo.badge.plus").font(.title2).frame(width: 56, height: 56)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.inspiration == nil ? "Pick an inspiration photo" : "Pick another photo").font(.headline)
                    Text("We'll restyle your room to match and find pieces to buy.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .padding(.horizontal)
    }

    @ViewBuilder private var styleSection: some View {
        if let style = model.style {
            VStack(alignment: .leading, spacing: 8) {
                Text(style.styleName).font(.title2.bold())
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
                errorCard(error.localizedDescription) { await model.reloadProducts() }
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
            Text(product.title).font(.subheadline).lineLimit(2, reservesSpace: true)
            HStack {
                Text(product.price).font(.subheadline.bold())
                Spacer()
                Text(product.retailer).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Link(destination: product.productURL) {
                Label("Open", systemImage: "arrow.up.right.square").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
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
    private(set) var style: VibeStyle?
    private(set) var render: Result<UIImage, Error>?
    private(set) var products: Result<[ShopProduct], Error>?
    private(set) var error: String?

    /// The current pick's run. A newer pick cancels it so its results can't land under the new photo.
    private var run: Task<Void, Never>?

    init(snapshot: UIImage, projectID: UUID?) {
        self.snapshot = snapshot.croppedToRenderAspect()
        self.projectID = projectID
    }

    func begin(with image: UIImage) {
        run?.cancel()
        run = Task { await start(with: image) }
    }

    func retryAnalyze() {
        if let inspiration { begin(with: inspiration) }
    }

    func cancel() { run?.cancel() }

    func fail(_ message: String) { error = message }

    private func start(with image: UIImage) async {
        inspiration = image
        style = nil; render = nil; products = nil; error = nil
        do {
            let analyzed = try await APIClient.shared.analyzeVibe(image)
            guard !Task.isCancelled else { return }
            style = analyzed
        } catch {
            if !Task.isCancelled && !(error is CancellationError) { self.error = error.localizedDescription }
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
        products = nil
        let result: Result<[ShopProduct], Error>
        do { result = .success(try await APIClient.shared.products(for: style)) } catch { result = .failure(error) }
        if !Task.isCancelled, style == self.style { products = result }
    }
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
