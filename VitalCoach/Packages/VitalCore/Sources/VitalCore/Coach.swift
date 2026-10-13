import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Models (mirrors supabase/migrations/20261013000001_phase2_coach.sql)

public enum CoachMode: String, Codable, Sendable {
    case chat
    case morningBriefing = "morning_briefing"
    case weeklySummary = "weekly_summary"
    case goalReassessment = "goal_reassessment"
    case checkinFollowup = "checkin_followup"
    case contextPreview = "context_preview"
}

public struct CoachSafety: Codable, Sendable, Equatable {
    public var urgent: Bool?
    public var needsClinician: Bool?
    public var topics: [String]?
}

/// Structured extras the server attaches to coach replies.
public struct CoachMetadata: Codable, Sendable, Equatable {
    /// "your_data" | "general_education" | "mixed" | "no_data"
    public var basis: String?
    public var dataPointsUsed: [String]?
    public var followUpQuestion: String?
    public var safety: CoachSafety?
    public var guardApplied: [String]?
    public var source: String?
    /// Compounds/interventions the user asked about; the app can offer a Research card for each
    /// (ResearchClient.insightCard). Empty or nil when none.
    public var researchTopics: [String]?

    public init() {}

    public var basisLabel: String? {
        switch basis {
        case "your_data": "Based on your data"
        case "general_education": "General education"
        case "mixed": "Your data + general education"
        case "no_data": "Not enough data"
        default: nil
        }
    }
}

public struct CoachMessage: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var conversationId: UUID
    /// "user" | "assistant" | "system_notice"
    public var role: String
    public var content: String
    public var metadata: CoachMetadata?
    public var createdAt: Date?

    public init(id: UUID, conversationId: UUID, role: String, content: String, metadata: CoachMetadata? = nil, createdAt: Date? = nil) {
        self.id = id; self.conversationId = conversationId; self.role = role; self.content = content
        self.metadata = metadata; self.createdAt = createdAt
    }

    public var isUser: Bool { role == "user" }
}

public struct CoachConversation: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var title: String
    public var kind: String
    public var updatedAt: Date?

    public init(id: UUID, title: String, kind: String, updatedAt: Date?) {
        self.id = id; self.title = title; self.kind = kind; self.updatedAt = updatedAt
    }
}

public struct CoachMemory: Codable, Sendable, Equatable, Identifiable {
    public enum Category: String, Codable, Sendable, CaseIterable {
        case preference, goalContext = "goal_context", healthContext = "health_context", routine, other
        public var displayName: String {
            switch self {
            case .preference: "Preference"
            case .goalContext: "Goal context"
            case .healthContext: "Health context"
            case .routine: "Routine"
            case .other: "Other"
            }
        }
    }
    public enum Status: String, Codable, Sendable { case proposed, active, archived }

    public var id: UUID
    public var category: Category
    public var content: String
    /// "user" or "coach"
    public var source: String
    public var status: Status
    public var createdAt: Date?
}

public struct InsightPayload: Codable, Sendable, Equatable {
    public var add: [String]?
    public var remove: [String]?
    public var rationale: String?
    public var basis: String?
    public var dataPointsUsed: [String]?
    public var followUpQuestion: String?
    public var goalProposal: GoalProposal?

    public struct GoalProposal: Codable, Sendable, Equatable {
        public var add: [String]
        public var remove: [String]
        public var rationale: String
    }

    public init() {}

    /// Goal changes proposed by the coach, as known goal values (unknown strings are dropped).
    public var goalsToAdd: [HealthGoal] { (add ?? goalProposal?.add ?? []).compactMap(HealthGoal.init(rawValue:)) }
    public var goalsToRemove: [HealthGoal] { (remove ?? goalProposal?.remove ?? []).compactMap(HealthGoal.init(rawValue:)) }
}

public struct CoachInsight: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    /// "morning_briefing" | "weekly_summary" | "goal_reassessment" | "goal_proposal"
    public var kind: String
    public var forDate: String
    public var title: String
    public var body: String
    public var payload: InsightPayload?
    /// "new" | "seen" | "accepted" | "dismissed"
    public var status: String
    public var createdAt: Date?
}

/// Response of the `coach` Edge Function.
public struct CoachResponse: Decodable, Sendable {
    public var conversationId: UUID?
    public var message: CoachMessage?
    public var insight: CoachInsight?
    public var goalProposal: CoachInsight?
    public var proposedMemories: Int?
    public var cached: Bool?
    public var urgent: Bool?
}

public enum CoachError: Error, Equatable, Sendable {
    case consentRequired(String)
    case limitReached(code: String, message: String)
    case notConfigured(String)
    case unavailable(String)
    case unauthorized
    case offline
    case badResponse

    public var userMessage: String {
        switch self {
        case .consentRequired(let m), .notConfigured(let m), .unavailable(let m): m
        case .limitReached(_, let m): m
        case .unauthorized: "Please sign in again to use the coach."
        case .offline: "The coach needs an internet connection."
        case .badResponse: "The coach sent an unexpected response. Please try again."
        }
    }
}

// MARK: - Pure helpers

public enum CoachDates {
    /// Local calendar date string the server uses for once-per-day briefings.
    public static func localDate(_ date: Date, timeZone: TimeZone) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        return LocalDate(date, calendar: cal).description
    }
}

public enum GoalProposalApplier {
    /// The goal set after accepting a proposal. Never changes anything by itself — the app calls
    /// this only when the user taps Accept.
    public static func apply(_ payload: InsightPayload, to current: Set<HealthGoal>) -> Set<HealthGoal> {
        var result = current.union(payload.goalsToAdd)
        result.subtract(payload.goalsToRemove)
        return result.isEmpty ? current : result // never leave the user with zero goals
    }
}

// MARK: - Client

/// Talks to the `coach` Edge Function and the coach tables (via PostgREST with the user's JWT,
/// so Row Level Security applies). The coach is online-only; nothing here is queued offline.
public struct CoachClient: Sendable {
    let config: SupabaseConfig
    let transport: any HTTPTransport
    let auth: SupabaseAuth

    public init(config: SupabaseConfig, transport: any HTTPTransport, auth: SupabaseAuth) {
        self.config = config; self.transport = transport; self.auth = auth
    }

    // Edge Function

    public func send(_ mode: CoachMode, message: String? = nil, conversationId: UUID? = nil, timeZone: TimeZone = .current,
                     now: Date = Date(), forceRefresh: Bool = false) async throws -> CoachResponse {
        let data = try await callFunction(body(mode, message: message, conversationId: conversationId, timeZone: timeZone, now: now, forceRefresh: forceRefresh))
        do { return try VitalJSON.decoder().decode(CoachResponse.self, from: data) } catch { throw CoachError.badResponse }
    }

    /// Exactly what the coach would see (no AI call). Returned as pretty-printed JSON text.
    public func contextPreview(timeZone: TimeZone = .current, now: Date = Date()) async throws -> String {
        let data = try await callFunction(body(.contextPreview, message: nil, conversationId: nil, timeZone: timeZone, now: now, forceRefresh: false))
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let ctx = obj["context"],
              let pretty = try? JSONSerialization.data(withJSONObject: ctx, options: [.prettyPrinted, .sortedKeys]) else {
            throw CoachError.badResponse
        }
        return String(decoding: pretty, as: UTF8.self)
    }

    func body(_ mode: CoachMode, message: String?, conversationId: UUID?, timeZone: TimeZone, now: Date, forceRefresh: Bool) -> Data {
        var b: [String: Any] = ["mode": mode.rawValue, "timezone": timeZone.identifier, "local_date": CoachDates.localDate(now, timeZone: timeZone)]
        if let message { b["message"] = message }
        if let conversationId { b["conversation_id"] = conversationId.uuidString.lowercased() }
        if forceRefresh { b["force_refresh"] = true }
        return (try? JSONSerialization.data(withJSONObject: b, options: [.sortedKeys])) ?? Data()
    }

    func callFunction(_ body: Data) async throws -> Data {
        var req = URLRequest(url: config.url.appending(path: "functions/v1/coach"))
        req.httpMethod = "POST"
        req.httpBody = body
        req.timeoutInterval = 90
        try await authorize(&req)
        let (data, resp) = try await sendMapped(req)
        return try Self.mapFunctionStatus(data, resp)
    }

    static func mapFunctionStatus(_ data: Data, _ resp: HTTPURLResponse) throws -> Data {
        if (200..<300).contains(resp.statusCode) { return data }
        struct E: Decodable { var error: String?; var message: String? }
        let e = (try? JSONDecoder().decode(E.self, from: data)) ?? E(error: nil, message: nil)
        let message = e.message ?? "The coach couldn't respond right now. Please try again."
        switch (resp.statusCode, e.error) {
        case (401, _): throw CoachError.unauthorized
        case (403, "consent_required"): throw CoachError.consentRequired(message)
        case (429, let code): throw CoachError.limitReached(code: code ?? "limit", message: message)
        case (503, "coach_not_configured"): throw CoachError.notConfigured(message)
        case (404, _): throw CoachError.notConfigured("The coach service isn't deployed yet.")
        default: throw CoachError.unavailable(message)
        }
    }

    // Tables (PostgREST, RLS-scoped)

    public func conversations(limit: Int = 50) async throws -> [CoachConversation] {
        try await get("coach_conversations", [("select", "id,title,kind,updated_at"), ("archived_at", "is.null"), ("kind", "eq.chat"),
                                              ("order", "updated_at.desc"), ("limit", "\(limit)")])
    }

    public func messages(conversationId: UUID, limit: Int = 200) async throws -> [CoachMessage] {
        try await get("coach_messages", [("select", "id,conversation_id,role,content,metadata,created_at"),
                                         ("conversation_id", "eq.\(conversationId.uuidString.lowercased())"),
                                         ("order", "created_at.asc"), ("limit", "\(limit)")])
    }

    public func deleteConversation(_ id: UUID) async throws {
        _ = try await rest("DELETE", "coach_conversations", [("id", "eq.\(id.uuidString.lowercased())")], body: nil)
    }

    public func memories() async throws -> [CoachMemory] {
        try await get("coach_memory", [("select", "id,category,content,source,status,created_at"), ("status", "in.(proposed,active)"),
                                       ("order", "created_at.desc")])
    }

    public func addMemory(userId: UUID, category: CoachMemory.Category, content: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["user_id": userId.uuidString.lowercased(), "category": category.rawValue,
                                                               "content": String(content.prefix(500)), "source": "user", "status": "active"])
        _ = try await rest("POST", "coach_memory", [], body: body)
    }

    public func updateMemory(_ id: UUID, content: String? = nil, status: CoachMemory.Status? = nil) async throws {
        var patch: [String: Any] = [:]
        if let content { patch["content"] = String(content.prefix(500)) }
        if let status { patch["status"] = status.rawValue }
        guard !patch.isEmpty else { return }
        _ = try await rest("PATCH", "coach_memory", [("id", "eq.\(id.uuidString.lowercased())")], body: try JSONSerialization.data(withJSONObject: patch))
    }

    public func deleteMemory(_ id: UUID) async throws {
        _ = try await rest("DELETE", "coach_memory", [("id", "eq.\(id.uuidString.lowercased())")], body: nil)
    }

    /// Deletes every memory the user owns (RLS limits the delete to their rows).
    public func clearMemory() async throws {
        _ = try await rest("DELETE", "coach_memory", [("id", "not.is.null")], body: nil)
    }

    public func insights(limit: Int = 30) async throws -> [CoachInsight] {
        try await get("generated_insights", [("select", "id,kind,for_date,title,body,payload,status,created_at"),
                                             ("order", "created_at.desc"), ("limit", "\(limit)")])
    }

    public func setInsightStatus(_ id: UUID, _ status: String) async throws {
        _ = try await rest("PATCH", "generated_insights", [("id", "eq.\(id.uuidString.lowercased())")],
                           body: try JSONSerialization.data(withJSONObject: ["status": status]))
    }

    // Plumbing

    private func get<T: Decodable>(_ table: String, _ query: [(String, String)]) async throws -> T {
        let data = try await rest("GET", table, query, body: nil)
        do { return try VitalJSON.decoder().decode(T.self, from: data) } catch { throw CoachError.badResponse }
    }

    private func rest(_ method: String, _ table: String, _ query: [(String, String)], body: Data?) async throws -> Data {
        var comps = URLComponents(url: config.url.appending(path: "rest/v1/\(table)"), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) } }
        comps.percentEncodedQuery = comps.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        req.httpBody = body
        req.timeoutInterval = 30
        if method != "GET" { req.setValue("return=minimal", forHTTPHeaderField: "Prefer") }
        try await authorize(&req)
        let (data, resp) = try await sendMapped(req)
        switch resp.statusCode {
        case 200..<300: return data
        case 401: throw CoachError.unauthorized
        default: throw CoachError.unavailable("Couldn't update the coach right now (HTTP \(resp.statusCode)).")
        }
    }

    private func authorize(_ req: inout URLRequest) async throws {
        let token: String
        do { token = try await auth.validAccessToken() } catch { throw CoachError.unauthorized }
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    private func sendMapped(_ req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do { return try await transport.send(req) } catch RemoteError.network { throw CoachError.offline }
    }
}
