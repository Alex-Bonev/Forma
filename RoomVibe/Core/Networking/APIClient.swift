import Foundation
import UIKit

/// Talks to our FastAPI backend (backend/main.py). The backend holds every provider key;
/// the app only knows the base URL and a shared secret.
///
/// Config: optional `APIConfig.json` next to this file (gitignored, bundled automatically by the synced folder),
/// written by `scripts/run_local.sh` for the demo server on the Mac:
///   {"baseURL": "http://<mac-lan-ip>:8000", "secret": "<APP_SHARED_SECRET>"}
/// Without it the app talks to `http://127.0.0.1:8000`, which only works from the Simulator.
struct APIConfig: Codable {
    var baseURL: URL
    var secret: String

    static let current: APIConfig = {
        if let url = Bundle.main.url(forResource: "APIConfig", withExtension: "json") {
            do {
                return try JSONDecoder().decode(APIConfig.self, from: Data(contentsOf: url))
            } catch {
                print("APIConfig.json is invalid, falling back to localhost: \(error)")   // else this fails silently
            }
        }
        return APIConfig(baseURL: URL(string: "http://127.0.0.1:8000")!, secret: "")
    }()
}

struct VibeStyle: Codable, Hashable {
    var styleName: String
    var palette: [String]
    var materials: [String]
    var furnitureTypes: [String]
    var decorItems: [String]
    var searchQueries: [String]
    // Optional so an older backend's Style still decodes; nil fields are left out when sent back.
    var roomType: String?
    var budgetUsd: Double?
    var shoppingList: [ShoppingItem]?

    struct ShoppingItem: Codable, Hashable {
        var category: String   // a CatalogItem id, or "decor"
        var query: String
        var maxPriceUsd: Double?
    }

    /// Text handed to /render so the restyled room matches the analyzed look.
    var renderPrompt: String {
        "\(styleName) style. Colors \(palette.joined(separator: ", ")). Materials: \(materials.joined(separator: ", ")). "
            + "Decor: \(decorItems.joined(separator: ", "))."
    }
}

struct ShopProduct: Codable, Hashable, Identifiable {
    var title: String
    var price: String
    var imageURL: URL?
    var productURL: URL
    var retailer: String
    // Set by the shopping agents (/vibe/shop), not by quick search.
    var priceUSD: Double?
    var category: String?
    var dimensionsCm: [Double]?   // [width, height, depth]
    var id: URL { productURL }

    enum CodingKeys: String, CodingKey {
        case title, price, retailer, category, dimensionsCm
        case imageURL = "imageUrl", productURL = "productUrl", priceUSD = "priceUsd"   // after convertFromSnakeCase
    }

    /// The backend sends "" for a missing thumbnail. Only web links are accepted, since they go straight to openURL.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decode(String.self, forKey: .title)
        price = try c.decode(String.self, forKey: .price)
        retailer = try c.decode(String.self, forKey: .retailer)
        imageURL = try c.decodeIfPresent(String.self, forKey: .imageURL).flatMap(URL.init(string:))
        priceUSD = try c.decodeIfPresent(Double.self, forKey: .priceUSD)
        category = try c.decodeIfPresent(String.self, forKey: .category)
        dimensionsCm = try c.decodeIfPresent([Double].self, forKey: .dimensionsCm).flatMap { $0.count == 3 ? $0 : nil }
        guard let url = URL(string: try c.decode(String.self, forKey: .productURL)),
              ["http", "https"].contains(url.scheme?.lowercased()) else {
            throw DecodingError.dataCorruptedError(forKey: .productURL, in: c, debugDescription: "not a web link")
        }
        productURL = url
    }
}

/// A started /vibe/shop run: poll `job` with `APIClient.pollShopping`.
struct ShopJob: Decodable, Hashable {
    var job: String
    var items: [Item]
    struct Item: Decodable, Hashable { var category: String; var query: String }
}

/// One poll of /vibe/shop/{job}. `chosen` and `totalUsd` arrive once every item has finished.
struct ShopStatus: Decodable {
    var done: Bool
    var budgetUsd: Double?
    var items: [Item]
    var chosen: [URL]?
    var totalUsd: Double?

    struct Item: Decodable {
        enum Status: String, Decodable { case running, done, failed }
        var category: String
        var query: String
        var status: Status
        var products: [ShopProduct]

        enum CodingKeys: String, CodingKey { case category, query, status, products }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            category = try c.decode(String.self, forKey: .category)
            query = try c.decode(String.self, forKey: .query)
            status = (try? c.decode(Status.self, forKey: .status)) ?? .failed
            products = try c.decode([Lossy<ShopProduct>].self, forKey: .products).compactMap(\.value)
        }
    }
}

/// One poll of /vibe/model3d/{id}. `usdz` arrives with `.done`; the model is not to real scale.
struct Model3DStatus: Decodable {
    enum Status: String, Decodable { case running, done, failed }
    var status: Status
    var usdz: Data?
    var error: String?

    enum CodingKeys: String, CodingKey { case status, usdzBase64, error }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = (try? c.decode(Status.self, forKey: .status)) ?? .failed
        usdz = try c.decodeIfPresent(String.self, forKey: .usdzBase64).flatMap { Data(base64Encoded: $0) }
        error = try c.decodeIfPresent(String.self, forKey: .error)
        if status == .done && usdz == nil { status = .failed }   // done without a readable model is no model
    }
}

/// Decodes an element or nil, so one bad item doesn't fail the whole list.
private struct Lossy<T: Decodable>: Decodable {
    var value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

enum APIError: LocalizedError {
    case offline, timeout, network(String), server(Int, String), badResponse

    var errorDescription: String? {
        switch self {
        case .offline: "You're offline. Check Wi-Fi and try again."
        case .timeout: "The AI took too long. Try again."
        case .network(let detail): "Network error: \(detail)"
        case .server(let code, let detail): "Server error \(code): \(detail)"
        case .badResponse: "The server sent something unexpected."
        }
    }
}

final class APIClient {
    static let shared = APIClient()

    private let config: APIConfig
    private let session: URLSession

    init(config: APIConfig = .current) {
        self.config = config
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 100   // backend gives providers 90 s
        session = URLSession(configuration: c)
    }

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.keyDecodingStrategy = .convertFromSnakeCase; return d
    }()
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.keyEncodingStrategy = .convertToSnakeCase; return e
    }()

    /// Checks the demo server is reachable before going on stage. Returns whether it runs in mock mode.
    func health() async throws -> Bool {
        struct Health: Decodable { var ok: Bool; var mock: Bool }
        return try await send(request("health"), as: Health.self).mock
    }

    /// `layout`: LayoutDescription text. `view`: "cutaway" (dollhouse angle) or "interior" (low camera).
    /// `structure`: optional flat-color map of the same view, sent as PNG so its colors stay exact.
    func render(_ image: UIImage, prompt: String = "", layout: String = "", view: String = "cutaway",
                structure: UIImage? = nil, styleRef: UIImage? = nil) async throws -> UIImage {
        struct Rendered: Decodable { var imageBase64: String }
        var form = Multipart()
        try form.addImage("image", image)
        form.addField("prompt", prompt)
        form.addField("layout", layout)
        form.addField("view", view)
        if let structure { try form.addImage("structure", structure, png: true) }
        if let styleRef { try form.addImage("style_ref", styleRef) }
        let out = try await send(form.request(request("render")), as: Rendered.self)
        guard let data = Data(base64Encoded: out.imageBase64), let result = UIImage(data: data) else {
            throw APIError.badResponse
        }
        return result
    }

    /// Either an inspiration photo, a description (which may state a budget), or both.
    func analyzeVibe(_ image: UIImage?, prompt: String = "") async throws -> VibeStyle {
        var form = Multipart()
        if let image { try form.addImage("image", image) }
        if !prompt.isEmpty { form.addField("prompt", prompt) }
        return try await send(form.request(request("vibe/analyze")), as: VibeStyle.self)
    }

    func products(for style: VibeStyle) async throws -> [ShopProduct] {
        struct Products: Decodable { var products: [Lossy<ShopProduct>] }
        var req = request("vibe/products")
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try Self.encoder.encode(style)
        return try await send(req, as: Products.self).products.compactMap(\.value)
    }

    /// Starts one shopping agent per item of `style.shoppingList`. `budget` overrides the style's own.
    func startShopping(_ style: VibeStyle, budget: Double? = nil) async throws -> ShopJob {
        struct Body: Encodable { var style: VibeStyle; var budgetUsd: Double? }
        var req = request("vibe/shop")
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try Self.encoder.encode(Body(style: style, budgetUsd: budget))
        return try await send(req, as: ShopJob.self)
    }

    func pollShopping(_ job: ShopJob) async throws -> ShopStatus {
        try await send(request("vibe/shop/\(job.job)"), as: ShopStatus.self)
    }

    /// Starts SAM 3D on a product photo (/vibe/model3d). Poll the returned id with `pollModel3D`.
    func startModel3D(imageURL: URL, category: String) async throws -> String {
        struct Body: Encodable { var imageUrl: String; var category: String }
        struct Started: Decodable { var requestId: String }
        var req = request("vibe/model3d")
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try Self.encoder.encode(Body(imageUrl: imageURL.absoluteString, category: category))
        return try await send(req, as: Started.self).requestId
    }

    func pollModel3D(_ id: String) async throws -> Model3DStatus {
        try await send(request("vibe/model3d/\(id)"), as: Model3DStatus.self)
    }

    // MARK: Plumbing

    private func request(_ path: String) -> URLRequest {
        var req = URLRequest(url: config.baseURL.appending(path: path))
        if !config.secret.isEmpty { req.setValue(config.secret, forHTTPHeaderField: "X-App-Secret") }
        return req
    }

    private func send<T: Decodable>(_ req: URLRequest, as: T.Type) async throws -> T {
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch let e as URLError {
            switch e.code {
            case .timedOut: throw APIError.timeout
            case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost,
                 .dataNotAllowed:
                throw APIError.offline
            case .cancelled: throw CancellationError()
            default: throw APIError.network(e.localizedDescription)
            }
        }
        guard let http = response as? HTTPURLResponse else { throw APIError.badResponse }
        if http.statusCode == 504 { throw APIError.timeout }   // provider timed out (or a proxy in front of the server)
        guard http.statusCode == 200 else {
            let detail = (try? JSONDecoder().decode(ErrorDetail.self, from: data))?.detail ?? "no details"
            throw APIError.server(http.statusCode, detail)
        }
        do { return try Self.decoder.decode(T.self, from: data) } catch { throw APIError.badResponse }
    }
}

/// FastAPI's error body: {"detail": "..."}.
private struct ErrorDetail: Decodable { var detail: String }

private struct Multipart {
    let boundary = "RoomVibe-\(UUID().uuidString)"
    var body = Data()

    mutating func addField(_ name: String, _ value: String) {
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
    }

    mutating func addImage(_ name: String, _ image: UIImage, png: Bool = false) throws {
        guard let data = png ? image.pngData() : image.uploadJPEG() else { throw APIError.badResponse }
        let (ext, type) = png ? ("png", "image/png") : ("jpg", "image/jpeg")
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(name).\(ext)\"\r\n"
                    + "Content-Type: \(type)\r\n\r\n")
        body.append(data)
        body.append("\r\n")
    }

    func request(_ base: URLRequest) -> URLRequest {
        var req = base
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body + Data("--\(boundary)--\r\n".utf8)
        return req
    }
}

private extension Data {
    mutating func append(_ s: String) { append(Data(s.utf8)) }
}

extension UIImage {
    /// Long edge <= 1536 px, JPEG 0.8: keeps uploads well under the backend's upload cap and quick over Wi-Fi.
    func uploadJPEG(maxEdge: CGFloat = 1536, quality: CGFloat = 0.8) -> Data? {
        let px = CGSize(width: size.width * scale, height: size.height * scale)
        let factor = min(1, maxEdge / max(px.width, px.height, 1))
        let target = CGSize(width: (px.width * factor).rounded(), height: (px.height * factor).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: target, format: format)
            .image { _ in draw(in: CGRect(origin: .zero, size: target)) }
            .jpegData(compressionQuality: quality)
    }
}
