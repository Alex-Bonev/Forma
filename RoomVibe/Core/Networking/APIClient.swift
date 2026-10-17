import Foundation
import UIKit

/// Talks to our FastAPI backend (backend/main.py). The backend holds every provider key;
/// the app only knows the base URL and a shared secret.
///
/// Config: optional `APIConfig.json` next to this file (gitignored, bundled automatically by the synced folder):
///   {"baseURL": "https://<project>.vercel.app", "secret": "<APP_SHARED_SECRET>"}
/// Without it the app talks to a local `MOCK=1 fastapi dev main.py` (works from the Simulator).
struct APIConfig: Codable {
    var baseURL: URL
    var secret: String

    static let current: APIConfig = {
        if let url = Bundle.main.url(forResource: "APIConfig", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let config = try? JSONDecoder().decode(APIConfig.self, from: data) {
            return config
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
    var id: URL { productURL }

    enum CodingKeys: String, CodingKey {
        case title, price, retailer
        case imageURL = "imageUrl", productURL = "productUrl"   // after convertFromSnakeCase
    }
}

enum APIError: LocalizedError {
    case offline, timeout, server(Int, String), badResponse

    var errorDescription: String? {
        switch self {
        case .offline: "You're offline. Check Wi-Fi and try again."
        case .timeout: "The AI took too long. Try again."
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

    /// Wakes a cold Vercel function before the demo. Returns whether the backend runs in mock mode.
    func health() async throws -> Bool {
        struct Health: Decodable { var ok: Bool; var mock: Bool }
        return try await send(request("health"), as: Health.self).mock
    }

    func render(_ image: UIImage, prompt: String = "", styleRef: UIImage? = nil) async throws -> UIImage {
        struct Rendered: Decodable { var imageBase64: String }
        var form = Multipart()
        try form.addImage("image", image)
        form.addField("prompt", prompt)
        if let styleRef { try form.addImage("style_ref", styleRef) }
        let out = try await send(form.request(request("render")), as: Rendered.self)
        guard let data = Data(base64Encoded: out.imageBase64), let result = UIImage(data: data) else {
            throw APIError.badResponse
        }
        return result
    }

    func analyzeVibe(_ image: UIImage) async throws -> VibeStyle {
        var form = Multipart()
        try form.addImage("image", image)
        return try await send(form.request(request("vibe/analyze")), as: VibeStyle.self)
    }

    func products(for style: VibeStyle) async throws -> [ShopProduct] {
        struct Products: Decodable { var products: [ShopProduct] }
        var req = request("vibe/products")
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try Self.encoder.encode(style)
        return try await send(req, as: Products.self).products
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
            default: throw e
            }
        }
        guard let http = response as? HTTPURLResponse else { throw APIError.badResponse }
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

    mutating func addImage(_ name: String, _ image: UIImage) throws {
        guard let jpeg = image.uploadJPEG() else { throw APIError.badResponse }
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(name).jpg\"\r\n"
                    + "Content-Type: image/jpeg\r\n\r\n")
        body.append(jpeg)
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
    /// Long edge <= 1536 px, JPEG 0.8: keeps uploads far below Vercel's 4.5 MB cap.
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
