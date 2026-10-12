import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Public, non-secret backend configuration. The anon key is designed to ship in clients;
/// all data access is enforced by Row Level Security. Never put the service-role key here.
public struct SupabaseConfig: Sendable, Equatable {
    public var url: URL
    public var anonKey: String

    public init(url: URL, anonKey: String) { self.url = url; self.anonKey = anonKey }

    /// Reads `SUPABASE_URL` / `SUPABASE_ANON_KEY` from an Info.plist-style dictionary.
    /// Returns nil when unset or still containing placeholder values.
    public static func from(info: [String: Any]) -> SupabaseConfig? {
        guard let rawURL = (info["SUPABASE_URL"] as? String)?.trimmingCharacters(in: .whitespaces),
              let key = (info["SUPABASE_ANON_KEY"] as? String)?.trimmingCharacters(in: .whitespaces),
              !rawURL.isEmpty, !key.isEmpty, !rawURL.contains("YOUR_"), !key.contains("YOUR_"),
              let url = URL(string: rawURL), url.scheme == "https" else { return nil }
        return SupabaseConfig(url: url, anonKey: key)
    }
}

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await withCheckedThrowingContinuation { cont in
            session.dataTask(with: request) { data, response, error in
                if let error { cont.resume(throwing: RemoteError.network(error.localizedDescription)); return }
                guard let http = response as? HTTPURLResponse else { cont.resume(throwing: RemoteError.network("no response")); return }
                cont.resume(returning: (data ?? Data(), http))
            }.resume()
        }
    }
}

public struct AuthSession: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date
    public var userId: UUID
    public var email: String?
}

/// Secure persistence of the session (Keychain on iOS).
public protocol SessionStorage: Sendable {
    func load() async -> AuthSession?
    func save(_ session: AuthSession?) async
}

public actor InMemorySessionStorage: SessionStorage {
    private var session: AuthSession?
    public init(_ s: AuthSession? = nil) { session = s }
    public func load() async -> AuthSession? { session }
    public func save(_ s: AuthSession?) async { session = s }
}

/// Minimal Supabase Auth (GoTrue) client.
/// Endpoints: `POST /auth/v1/token?grant_type=id_token` (native Sign in with Apple) and
/// `POST /auth/v1/token?grant_type=refresh_token`, `POST /auth/v1/logout`.
public actor SupabaseAuth {
    private let config: SupabaseConfig
    private let transport: any HTTPTransport
    private let storage: any SessionStorage
    private let time: any TimeSource
    private var cached: AuthSession?
    private var loaded = false
    private var refreshTask: Task<AuthSession, Error>?

    public init(config: SupabaseConfig, transport: any HTTPTransport, storage: any SessionStorage, time: any TimeSource = SystemTimeSource()) {
        self.config = config; self.transport = transport; self.storage = storage; self.time = time
    }

    public func currentSession() async -> AuthSession? {
        if !loaded { cached = await storage.load(); loaded = true }
        return cached
    }

    /// Exchanges an Apple identity token for a Supabase session.
    /// `rawNonce` is the unhashed nonce; Apple received its SHA-256 hash.
    public func signInWithApple(idToken: String, rawNonce: String) async throws -> AuthSession {
        let body = try JSONSerialization.data(withJSONObject: ["provider": "apple", "id_token": idToken, "nonce": rawNonce])
        let s = try await tokenRequest(grantType: "id_token", body: body)
        await store(s)
        return s
    }

    /// Returns a non-expired access token, refreshing (once, de-duplicated) when needed.
    public func validAccessToken() async throws -> String {
        guard let s = await currentSession() else { throw RemoteError.unauthorized }
        if s.expiresAt.timeIntervalSince(time.now) > 60 { return s.accessToken }
        return try await refresh().accessToken
    }

    @discardableResult
    public func refresh() async throws -> AuthSession {
        if let t = refreshTask { return try await t.value }
        guard let s = await currentSession() else { throw RemoteError.unauthorized }
        let body = try JSONSerialization.data(withJSONObject: ["refresh_token": s.refreshToken])
        let task = Task { try await self.tokenRequest(grantType: "refresh_token", body: body) }
        refreshTask = task
        defer { refreshTask = nil }
        do {
            let new = try await task.value
            await store(new)
            return new
        } catch RemoteError.unauthorized {
            await store(nil)
            throw RemoteError.unauthorized
        }
    }

    public func signOut() async {
        if let s = await currentSession() {
            var req = URLRequest(url: config.url.appending(path: "auth/v1/logout"))
            req.httpMethod = "POST"
            req.setValue(config.anonKey, forHTTPHeaderField: "apikey")
            req.setValue("Bearer \(s.accessToken)", forHTTPHeaderField: "Authorization")
            _ = try? await transport.send(req) // best effort; local session is cleared regardless
        }
        await store(nil)
    }

    private func store(_ s: AuthSession?) async {
        cached = s; loaded = true
        await storage.save(s)
    }

    private struct TokenResponse: Decodable {
        var accessToken: String
        var refreshToken: String
        var expiresIn: Double
        var user: User
        struct User: Decodable { var id: UUID; var email: String? }
    }

    private func tokenRequest(grantType: String, body: Data) async throws -> AuthSession {
        var comps = URLComponents(url: config.url.appending(path: "auth/v1/token"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "grant_type", value: grantType)]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "POST"
        req.httpBody = body
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        let (data, resp) = try await transport.send(req)
        switch resp.statusCode {
        case 200..<300: break
        case 400, 401, 403: throw RemoteError.unauthorized
        case 429: throw RemoteError.rateLimited(retryAfter: nil)
        default: throw RemoteError.server(status: resp.statusCode)
        }
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        let t = try d.decode(TokenResponse.self, from: data)
        return AuthSession(accessToken: t.accessToken, refreshToken: t.refreshToken,
                           expiresAt: time.now.addingTimeInterval(t.expiresIn), userId: t.user.id, email: t.user.email)
    }
}

/// PostgREST adapter. Every request carries the user's JWT, so Row Level Security decides
/// what is visible — the client never filters by user id for security.
public struct SupabaseRemoteStore: RemoteStore {
    let config: SupabaseConfig
    let transport: any HTTPTransport
    let auth: SupabaseAuth

    public init(config: SupabaseConfig, transport: any HTTPTransport, auth: SupabaseAuth) {
        self.config = config; self.transport = transport; self.auth = auth
    }

    public func upsert(_ entity: EntityName, payload: Data) async throws -> Data {
        var req = try await request(entity, query: [URLQueryItem(name: "on_conflict", value: "id")])
        req.httpMethod = "POST"
        req.httpBody = Data("[".utf8) + payload + Data("]".utf8)
        req.setValue("resolution=merge-duplicates,return=representation", forHTTPHeaderField: "Prefer")
        return try await send(req)
    }

    public func changes(_ entity: EntityName, after cursor: SyncCursor?, limit: Int) async throws -> Data {
        var q = [URLQueryItem(name: "select", value: "*"),
                 URLQueryItem(name: "order", value: "server_updated_at.asc,id.asc"),
                 URLQueryItem(name: "limit", value: String(limit))]
        if let c = cursor {
            if let id = c.id {
                let ts = "\"\(c.serverUpdatedAt)\""
                q.append(URLQueryItem(name: "or", value: "(server_updated_at.gt.\(ts),and(server_updated_at.eq.\(ts),id.gt.\(id.uuidString.lowercased())))"))
            } else {
                q.append(URLQueryItem(name: "server_updated_at", value: "gte.\(c.serverUpdatedAt)"))
            }
        }
        var req = try await request(entity, query: q)
        req.httpMethod = "GET"
        return try await send(req)
    }

    public func fetch(_ entity: EntityName, id: UUID) async throws -> Data {
        var req = try await request(entity, query: [URLQueryItem(name: "select", value: "*"),
                                                    URLQueryItem(name: "id", value: "eq.\(id.uuidString.lowercased())")])
        req.httpMethod = "GET"
        return try await send(req)
    }

    private func request(_ entity: EntityName, query: [URLQueryItem]) async throws -> URLRequest {
        var comps = URLComponents(url: config.url.appending(path: "rest/v1/\(entity.rawValue)"), resolvingAgainstBaseURL: false)!
        comps.queryItems = query
        // URLComponents leaves "+" unescaped; in timestamps it must be %2B or PostgREST reads a space.
        comps.percentEncodedQuery = comps.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        var req = URLRequest(url: comps.url!)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(try await auth.validAccessToken())", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 30
        return req
    }

    private func send(_ req: URLRequest) async throws -> Data {
        let (data, resp) = try await transport.send(req)
        return try Self.check(data, resp)
    }

    static func check(_ data: Data, _ resp: HTTPURLResponse) throws -> Data {
        switch resp.statusCode {
        case 200..<300: return data
        case 401: throw RemoteError.unauthorized
        case 409: throw RemoteError.conflict
        case 429: throw RemoteError.rateLimited(retryAfter: resp.value(forHTTPHeaderField: "Retry-After").flatMap { Double($0) })
        case 500...: throw RemoteError.server(status: resp.statusCode)
        default:
            // Log only the PostgREST error code, never the body (it may echo health data).
            struct PGErr: Decodable { var code: String? }
            let code = (try? JSONDecoder().decode(PGErr.self, from: data))?.code ?? "unknown"
            throw RemoteError.invalidPayload("HTTP \(resp.statusCode) code \(code)")
        }
    }
}

/// Account-level operations that need privileged server code (Edge Functions).
public struct AccountService: Sendable {
    let config: SupabaseConfig
    let transport: any HTTPTransport
    let auth: SupabaseAuth

    public init(config: SupabaseConfig, transport: any HTTPTransport, auth: SupabaseAuth) {
        self.config = config; self.transport = transport; self.auth = auth
    }

    /// Calls the `delete-account` Edge Function, which deletes the auth user; database rows
    /// cascade-delete. The caller must then wipe local data and sign out.
    public func deleteAccount() async throws {
        var req = URLRequest(url: config.url.appending(path: "functions/v1/delete-account"))
        req.httpMethod = "POST"
        req.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(try await auth.validAccessToken())", forHTTPHeaderField: "Authorization")
        req.httpBody = Data(#"{"confirm":true}"#.utf8)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, resp) = try await transport.send(req)
        _ = try SupabaseRemoteStore.check(data, resp)
    }
}
