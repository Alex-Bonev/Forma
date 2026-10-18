import Foundation
import os
import Security

/// Supabase project the library syncs to (supabase/migrations). From `APIConfig.json`, written by
/// `scripts/run_local.sh` from SUPABASE_URL / SUPABASE_PUBLISHABLE_KEY in backend/.env. nil = local only.
struct CloudConfig: Codable {
    var url: URL
    /// The publishable (or legacy anon) key. Safe to ship in the app: RLS is what guards the data.
    var key: String
}

enum CloudError: LocalizedError {
    case http(Int, String), badResponse(String)

    var errorDescription: String? {
        switch self {
        case .http(let code, let detail): "Cloud error \(code): \(detail)"
        case .badResponse(let detail): "The cloud sent something unexpected: \(detail)"
        }
    }
}

/// Thin REST client for Supabase Auth, PostgREST and Storage. Every install signs in anonymously once; the
/// session lives in the Keychain so a reinstall keeps the same user (and so the same cloud library).
/// Use one instance per process (`CloudClient.shared`): refresh tokens rotate, and a second copy would reuse a
/// spent one.
actor CloudClient {
    /// The process's only client, from `APIConfig.json`'s cloud section. nil = no cloud config.
    static let shared: CloudClient? = APIConfig.current.cloud.map { CloudClient(config: $0) }

    struct Session: Codable {
        var accessToken: String
        var refreshToken: String
        var expiresAt: Date
        var userID: UUID
    }

    static let bucket = "library"
    private static let pageSize = 500

    private let config: CloudConfig
    private let session: URLSession
    private var auth: Session?
    private var signingIn: Task<Session, Error>?
    private var tokenFailedAt: Date?   // last failed sign-in: `accessToken()` waits 30 s after it
    private let log = Logger(subsystem: "RoomVibe", category: "CloudClient")

    init(config: CloudConfig) {
        self.config = config
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 60
        session = URLSession(configuration: c)
        auth = Keychain.load()
    }

    /// No key strategy: the docs are the app's own Codable types and must round-trip unchanged
    /// (`convertToSnakeCase` would turn Placement.objectID into object_id and back into objectId).
    static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .custom(encodeDate); return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .custom(decodeDate); return d
    }()

    // MARK: Auth

    /// The signed-in user, signing in (or refreshing the token) first when needed.
    func user() async throws -> UUID { try await validSession().userID }

    /// The current access token for the backend, or nil. Refresh only: never signs up a new user (only
    /// `validSession()` does, for CloudSync), never waits behind a sign-in already running, and after any failed
    /// sign-in waits 30 s before trying again, so backend calls can't stall or start a sign-in storm.
    func accessToken() async -> String? {
        if let auth, auth.expiresAt.timeIntervalSinceNow > 60 { return auth.accessToken }
        guard signingIn == nil, let previous = auth, (tokenFailedAt?.timeIntervalSinceNow ?? -.infinity) < -30 else {
            return nil
        }
        return try? await startSignIn(previous: previous, signUp: false).value.accessToken
    }

    private func validSession() async throws -> Session {
        if let auth, auth.expiresAt.timeIntervalSinceNow > 60 { return auth }
        if let signingIn { return try await signingIn.value }   // one sign-in at a time
        return try await startSignIn(previous: auth, signUp: true).value
    }

    /// Starts the one sign-in in flight. `signUp: false` only refreshes `previous` and fails when that is rejected.
    private func startSignIn(previous: Session?, signUp: Bool) -> Task<Session, Error> {
        let task = Task {
            defer { self.signingIn = nil }
            let new: Session
            do {
                new = try await self.signIn(refresh: previous?.refreshToken, signUp: signUp)
            } catch {
                self.tokenFailedAt = .now   // every failure, whoever started it, pauses `accessToken()`
                throw error
            }
            if let previous, previous.userID != new.userID {
                // The old session was revoked: its cloud rows stay with the old user, and local data re-uploads.
                self.log.warning("cloud user changed from \(previous.userID, privacy: .public) to \(new.userID, privacy: .public)")
            }
            self.auth = new
            Keychain.save(new)
            return new
        }
        signingIn = task
        return task
    }

    /// The token was rejected mid-session (revoked, or the clock is off): sign in again on the next request.
    private func expireSession() {
        auth?.expiresAt = .distantPast
    }

    /// Refreshes the stored session, or (with `signUp`) signs up a new anonymous user when there is none or the refresh
    /// token is no longer valid. Rate limits, server errors and network errors throw: they must not cost the user their library.
    private func signIn(refresh: String?, signUp: Bool = true) async throws -> Session {
        struct Token: Decodable {
            var accessToken: String, refreshToken: String, expiresIn: Double, user: User
            enum CodingKeys: String, CodingKey {
                case user, accessToken = "access_token", refreshToken = "refresh_token", expiresIn = "expires_in"
            }
        }
        struct User: Decodable { var id: UUID }
        var req: URLRequest
        if let refresh {
            req = URLRequest(url: config.url.appending(path: "auth/v1/token").appending(queryItems: [.init(name: "grant_type", value: "refresh_token")]))
            req.httpBody = try JSONEncoder().encode(["refresh_token": refresh])
        } else {
            req = URLRequest(url: config.url.appending(path: "auth/v1/signup"))
            req.httpBody = Data("{}".utf8)
        }
        req.httpMethod = "POST"
        req.setValue(config.key, forHTTPHeaderField: "apikey")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let token: Token
        do {
            token = try decode(Token.self, await send(req))
        } catch CloudError.http(let code, let detail) where signUp && refresh != nil && [400, 401].contains(code) && detail.contains("refresh_token") {
            return try await signIn(refresh: nil)   // refresh_token_not_found / refresh_token_already_used
        }
        return Session(accessToken: token.accessToken, refreshToken: token.refreshToken,
                       expiresAt: .now.addingTimeInterval(token.expiresIn), userID: token.user.id)
    }

    // MARK: Database (PostgREST)

    /// Every row of `table` the user can see (RLS limits that to their own), a page at a time: PostgREST caps
    /// one response at the project's max rows.
    func select<T: Decodable>(_ table: String, as: T.Type) async throws -> [T] {
        var rows: [T] = []
        while true {
            let url = config.url.appending(path: "rest/v1/\(table)").appending(queryItems: [
                .init(name: "select", value: "*"), .init(name: "order", value: "id"),
                .init(name: "limit", value: "\(Self.pageSize)"), .init(name: "offset", value: "\(rows.count)"),
            ])
            let page = try decode([T].self, await send { try await self.authorized(URLRequest(url: url)) })
            rows += page
            if page.count < Self.pageSize { return rows }
        }
    }

    /// Inserts the row, or replaces its columns when its id exists.
    /// Returns whether the row was stored: the last-writer-wins trigger skips a stale write, which PostgREST still
    /// reports as success, just with no row in the response.
    private struct Stored: Decodable { var id: UUID }

    @discardableResult
    func upsert<T: Encodable>(_ table: String, _ row: T) async throws -> Bool {
        let url = config.url.appending(path: "rest/v1/\(table)").appending(queryItems: [
            .init(name: "on_conflict", value: "id"), .init(name: "select", value: "id"),
        ])
        let body = try Self.encoder.encode([row])
        let data = try await send {
            var req = try await self.authorized(URLRequest(url: url))
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("resolution=merge-duplicates,return=representation", forHTTPHeaderField: "Prefer")
            req.httpBody = body
            return req
        }
        return try decode([Stored].self, data).count == 1
    }

    /// Sets the given columns on the row with `id`, if there is one. Returns whether the row was changed: no row
    /// with that id, or a stale write the last-writer-wins trigger skipped, comes back as an empty response.
    @discardableResult
    func update<T: Encodable>(_ table: String, id: UUID, _ values: T) async throws -> Bool {
        let url = config.url.appending(path: "rest/v1/\(table)").appending(queryItems: [
            .init(name: "id", value: "eq.\(id.uuidString.lowercased())"), .init(name: "select", value: "id"),
        ])
        let body = try Self.encoder.encode(values)
        let data = try await send {
            var req = try await self.authorized(URLRequest(url: url))
            req.httpMethod = "PATCH"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("return=representation", forHTTPHeaderField: "Prefer")
            req.httpBody = body
            return req
        }
        return try decode([Stored].self, data).count == 1
    }

    // MARK: Storage

    /// `path` is relative to the user's folder: "projects/<id>/thumb.jpg".
    func upload(_ file: URL, to path: String) async throws {
        _ = try await send(fromFile: file) {
            let owner = try await self.folder()
            var req = try await self.authorized(URLRequest(url: self.config.url.appending(path: "storage/v1/object/\(Self.bucket)/\(owner)/\(path)")))
            req.httpMethod = "POST"
            req.setValue("true", forHTTPHeaderField: "x-upsert")
            req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            return req
        }
    }

    /// Downloads to a new temporary file that the caller owns (and moves into place).
    func download(_ path: String) async throws -> URL {
        for attempt in 0..<2 {
            let owner = try await folder()
            let url = config.url.appending(path: "storage/v1/object/authenticated/\(Self.bucket)/\(owner)/\(path)")
            let req = try await authorized(URLRequest(url: url))
            let (file, response) = try await mapErrors { try await session.download(for: req) }
            guard let http = response as? HTTPURLResponse else { throw CloudError.badResponse("no HTTP response") }
            if http.statusCode == 200 {
                // URLSession may delete its own file once this returns: move it somewhere ours first.
                let kept = FileManager.default.temporaryDirectory.appending(path: "cloud-\(UUID().uuidString)")
                try FileManager.default.moveItem(at: file, to: kept)
                return kept
            }
            let detail = (try? String(contentsOf: file, encoding: .utf8)) ?? "no details"
            try? FileManager.default.removeItem(at: file)
            guard http.statusCode == 401, attempt == 0 else { throw CloudError.http(http.statusCode, detail) }
            expireSession()
        }
        throw CloudError.badResponse("unreachable")
    }

    /// Deletes files by user-relative path. Missing files are not an error.
    func remove(_ paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        let owner = try await folder()
        let body = try JSONEncoder().encode(["prefixes": paths.map { "\(owner)/\($0)" }])
        _ = try await send {
            var req = try await self.authorized(URLRequest(url: self.config.url.appending(path: "storage/v1/object/\(Self.bucket)")))
            req.httpMethod = "DELETE"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
            return req
        }
    }

    /// The user's top folder in the bucket. Lowercase: storage RLS compares it to `auth.uid()::text`, and Swift
    /// prints UUIDs uppercase.
    private func folder() async throws -> String { try await user().uuidString.lowercased() }

    // MARK: Plumbing

    private func authorized(_ base: URLRequest) async throws -> URLRequest {
        var req = base
        req.setValue(config.key, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(try await validSession().accessToken)", forHTTPHeaderField: "Authorization")
        return req
    }

    /// Sends an authorized request, retrying once with a fresh session if the token is rejected (401).
    private func send(fromFile file: URL? = nil, _ make: () async throws -> URLRequest) async throws -> Data {
        do {
            return try await send(make(), fromFile: file)
        } catch CloudError.http(401, _) {
            expireSession()
            return try await send(make(), fromFile: file)
        }
    }

    private func send(_ req: URLRequest, fromFile file: URL? = nil) async throws -> Data {
        let (data, response) = try await mapErrors {
            if let file { try await session.upload(for: req, fromFile: file) } else { try await session.data(for: req) }
        }
        guard let http = response as? HTTPURLResponse else { throw CloudError.badResponse("no HTTP response") }
        guard (200..<300).contains(http.statusCode) else {
            throw CloudError.http(http.statusCode, String(data: data.prefix(500), encoding: .utf8) ?? "no details")
        }
        return data
    }

    /// Same offline / timeout errors as APIClient, so callers can tell "no network" from a real failure.
    private func mapErrors<T>(_ body: () async throws -> T) async throws -> T {
        do { return try await body() } catch let e as URLError {
            switch e.code {
            case .timedOut: throw APIError.timeout
            case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dataNotAllowed:
                throw APIError.offline
            case .cancelled: throw CancellationError()
            default: throw APIError.network(e.localizedDescription)
            }
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try Self.decoder.decode(T.self, from: data) } catch { throw CloudError.badResponse("\(error)") }
    }

    // Postgres timestamptz <-> Date, at millisecond precision both ways (see `Date.syncStamp`).
    @Sendable private static func encodeDate(_ date: Date, _ encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(syncString(date))
    }

    /// UTC, "...T12:00:00.123Z", with the millisecond rounded. ISO8601FormatStyle truncates the fraction, and a
    /// `syncStamp` like .123 is stored as .12299999…, so it would go out 1 ms low and drift on every round trip.
    static func syncString(_ date: Date) -> String {
        let ms = Int64((date.timeIntervalSince1970 * 1000).rounded())
        let seconds = ms >= 0 ? ms / 1000 : (ms - 999) / 1000   // floor, so the fraction is never negative
        let whole = Date.ISO8601FormatStyle().format(Date(timeIntervalSince1970: TimeInterval(seconds)))
        return whole.dropLast() + String(format: ".%03lldZ", ms - seconds * 1000)
    }

    @Sendable static func decodeDate(_ decoder: Decoder) throws -> Date {
        let c = try decoder.singleValueContainer()
        let s = try c.decode(String.self)
        if let d = parseDate(s) { return d }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "not an ISO 8601 date: \(s)")
    }

    /// PostgREST sends "2026-10-17T12:00:00.123456+00:00": up to 6 fraction digits, or none. ISO8601FormatStyle
    /// reads 3 at most, so the fraction is cut to milliseconds first (that is all `syncStamp` keeps anyway).
    static func parseDate(_ s: String) -> Date? {
        var s = s
        if let dot = s.firstIndex(of: "."), let end = s[dot...].firstIndex(where: { !$0.isNumber && $0 != "." }) {
            let digits = s[s.index(after: dot)..<end]
            s.replaceSubrange(s.index(after: dot)..<end, with: (digits + "000").prefix(3))
        }
        for style in [Date.ISO8601FormatStyle(includingFractionalSeconds: true), Date.ISO8601FormatStyle()] {
            if let d = try? style.parse(s) { return d }
        }
        return nil
    }
}

extension Date {
    /// Now, rounded to the millisecond, for `updatedAt` and file times: survives the round trip through Postgres
    /// and JSON exactly, so equal stamps compare equal and sync does not re-upload unchanged items.
    static var syncStamp: Date { Date(timeIntervalSince1970: (Date.now.timeIntervalSince1970 * 1000).rounded() / 1000) }

    /// Equal within a millisecond (see `syncStamp`).
    func syncEquals(_ other: Date) -> Bool { abs(timeIntervalSince(other)) < 0.001 }
}

/// The auth session, in the Keychain: it holds a refresh token, which is a credential.
private enum Keychain {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "RoomVibe.cloud",
        kSecAttrAccount as String: "session",
    ]
    private static let log = Logger(subsystem: "RoomVibe", category: "CloudClient")

    static func load() -> CloudClient.Session? {
        var q = query
        q[kSecReturnData as String] = true
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(CloudClient.Session.self, from: data)
    }

    /// A lost save means a new anonymous user on the next launch, so failures are logged.
    static func save(_ session: CloudClient.Session) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = query
            q[kSecValueData as String] = data
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(q as CFDictionary, nil)
        }
        if status != errSecSuccess { log.error("could not save the cloud session to the Keychain: \(status)") }
    }
}
