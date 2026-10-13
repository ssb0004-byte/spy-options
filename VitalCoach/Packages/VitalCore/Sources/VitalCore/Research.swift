import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Evidence levels (mirrors supabase/functions/research/lib/evidence.ts)

/// Seven-level evidence classification. The server caps any level the AI claims to what the
/// verified citations support, so the UI can display it as-is. Ordered weakest → strongest.
public enum EvidenceLevel: String, Codable, Sendable, CaseIterable, Comparable {
    case established = "established_human"
    case moderate = "moderate_human"
    case preliminary = "preliminary_human"
    case preclinicalAnimal = "preclinical_animal"
    case inVitro = "in_vitro_mechanistic"
    case anecdotal = "anecdotal_community"
    case insufficient

    /// 6 = strongest (established) … 0 = insufficient.
    public var rank: Int {
        switch self {
        case .established: 6
        case .moderate: 5
        case .preliminary: 4
        case .preclinicalAnimal: 3
        case .inVitro: 2
        case .anecdotal: 1
        case .insufficient: 0
        }
    }

    public static func < (lhs: EvidenceLevel, rhs: EvidenceLevel) -> Bool { lhs.rank < rhs.rank }

    /// True for the three levels that come from studies in people.
    public var isHumanEvidence: Bool { rank >= EvidenceLevel.preliminary.rank }

    public var displayName: String {
        switch self {
        case .established: "Established human evidence"
        case .moderate: "Moderate human evidence"
        case .preliminary: "Preliminary human evidence"
        case .preclinicalAnimal: "Animal studies only"
        case .inVitro: "Lab/mechanism studies only"
        case .anecdotal: "Anecdotal reports only (unverified)"
        case .insufficient: "Insufficient evidence"
        }
    }

    public var shortName: String {
        switch self {
        case .established: "Established"
        case .moderate: "Moderate"
        case .preliminary: "Preliminary"
        case .preclinicalAnimal: "Animal only"
        case .inVitro: "Lab only"
        case .anecdotal: "Anecdotal"
        case .insufficient: "Insufficient"
        }
    }

    /// Plain-language meaning, matching the server's LEVEL_INFO.
    public var explanation: String {
        switch self {
        case .established:
            "Supported by systematic reviews/meta-analyses or several randomized controlled trials in people (or an FDA approval for a labeled use). Results are fairly consistent, but individual responses still vary."
        case .moderate:
            "At least one randomized controlled trial in people supports it, but the evidence is limited in size, duration or consistency. Future studies could change the picture."
        case .preliminary:
            "Only small, uncontrolled or observational human studies, case reports or unpublished trial results. These can suggest an effect but cannot show that it works."
        case .preclinicalAnimal:
            "Findings come from animal studies. Many results in animals do not translate to people, and safe or effective human use is unknown."
        case .inVitro:
            "Findings come from cells or test tubes. They show a possible mechanism, not an effect in a living person."
        case .anecdotal:
            "Based on personal stories, forums or marketing — not studies. These reports are unverified and subject to strong biases."
        case .insufficient:
            "We could not find enough reliable evidence to say whether it works or is safe. Missing evidence is not evidence of safety."
        }
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = EvidenceLevel(rawValue: raw) ?? .insufficient // unknown → most conservative
    }
}

// MARK: - Models

public struct Citation: Codable, Sendable, Equatable, Hashable, Identifiable {
    public enum Source: String, Codable, Sendable {
        case pubmed, clinicaltrials, fdaLabel = "fda_label"
        public var displayName: String {
            switch self {
            case .pubmed: "PubMed"
            case .clinicaltrials: "ClinicalTrials.gov"
            case .fdaLabel: "FDA label"
            }
        }
    }
    public var source: Source
    /// PMID, NCT number or openFDA set_id.
    public var id: String
    public var title: String
    public var year: Int?
    public var url: String
    public var publicationTypes: [String]
    /// "meta_analysis", "systematic_review", "rct", "clinical_trial", "observational", "case_report", "guideline",
    /// "review", "animal", "in_vitro", "trial_registration", "trial_with_results", "regulatory_label", "other".
    public var studyKind: String?
    public var retrievedAt: Date?

    public init(source: Source, id: String, title: String, year: Int?, url: String, publicationTypes: [String], studyKind: String? = nil, retrievedAt: Date? = nil) {
        self.source = source; self.id = id; self.title = title; self.year = year; self.url = url
        self.publicationTypes = publicationTypes; self.studyKind = studyKind; self.retrievedAt = retrievedAt
    }

    public var link: URL? { URL(string: url) }

    /// e.g. "Meta-analysis", "Randomized trial", "Animal study".
    public var studyKindLabel: String {
        switch studyKind {
        case "meta_analysis": "Meta-analysis"
        case "systematic_review": "Systematic review"
        case "rct": "Randomized controlled trial"
        case "clinical_trial": "Clinical trial (non-randomized)"
        case "observational": "Observational study"
        case "case_report": "Case report/series"
        case "guideline": "Clinical guideline"
        case "review": "Narrative review"
        case "animal": "Animal study"
        case "in_vitro": "Lab (in vitro) study"
        case "trial_registration": "Registered trial (no results)"
        case "trial_with_results": "Trial with posted results"
        case "regulatory_label": "FDA-approved label"
        default: "Other"
        }
    }
}

public struct EvidenceAssessment: Codable, Sendable, Equatable {
    public var level: EvidenceLevel
    public var claimedLevel: EvidenceLevel?
    public var label: String?
    /// Plain-language meaning of `level`.
    public var explanation: String?
    /// The AI's own explanation (after server guards).
    public var modelExplanation: String?
    /// True when the server lowered the AI's claim to what the citations support.
    public var capped: Bool
    public var capReason: String?
    public var supportedBy: String?

    public init(level: EvidenceLevel, claimedLevel: EvidenceLevel? = nil, capped: Bool = false) {
        self.level = level; self.claimedLevel = claimedLevel; self.capped = capped
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        level = try c.decode(EvidenceLevel.self, forKey: .level)
        claimedLevel = try c.decodeIfPresent(EvidenceLevel.self, forKey: .claimedLevel)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        explanation = try c.decodeIfPresent(String.self, forKey: .explanation)
        modelExplanation = try c.decodeIfPresent(String.self, forKey: .modelExplanation)
        capped = try c.decodeIfPresent(Bool.self, forKey: .capped) ?? false
        capReason = try c.decodeIfPresent(String.self, forKey: .capReason)
        supportedBy = try c.decodeIfPresent(String.self, forKey: .supportedBy)
    }

    public var displayExplanation: String { explanation ?? level.explanation }
}

public struct AnecdotalReports: Codable, Sendable, Equatable {
    public struct Bias: Codable, Sendable, Equatable, Hashable { public var name: String; public var explanation: String }
    public var summary: String
    /// Always false: anecdotes are never verified evidence.
    public var verified: Bool
    public var label: String
    public var biases: [Bias]
}

public struct RegulatoryStatus: Codable, Sendable, Equatable {
    public struct Wada: Codable, Sendable, Equatable { public var status: String; public var note: String? }
    /// "approved_label" | "label_without_application" | "no_label_found" | "unknown"
    public var fda: String
    public var summary: String
    public var wada: Wada?
    public var sources: [String]?
    /// YYYY-MM-DD the FDA source was checked.
    public var checkedAt: String?

    public var fdaDisplayName: String {
        switch fda {
        case "approved_label": "FDA-approved drug label"
        case "label_without_application": "FDA label listed (approval not confirmed)"
        case "no_label_found": "No FDA drug label found"
        default: "Unknown"
        }
    }
}

public struct InteractionFlag: Codable, Sendable, Equatable, Hashable {
    /// The user's compound(s), condition or allergy this flag is about.
    public var with: String
    /// "drug_interaction" | "condition" | "allergy" | "no_data"
    public var kind: String
    /// "avoid_unless_clinician_approves" | "caution" | "unknown"
    public var severity: String
    public var detail: String
    /// "fda_label:<set_id>" | "curated_rule" | "no_data"
    public var source: String

    public var severityDisplayName: String {
        switch severity {
        case "avoid_unless_clinician_approves": "Avoid unless your clinician approves"
        case "caution": "Use caution — check with a pharmacist"
        default: "Unknown — no data"
        }
    }
}

public struct EstablishedApproach: Codable, Sendable, Equatable, Hashable {
    public var name: String
    /// "non_drug" | "otc" | "prescription" | "supplement" | "clinician"
    public var kind: String
    public var note: String
}

public struct SourceCheck: Codable, Sendable, Equatable {
    public var source: Citation.Source
    public var ok: Bool
    public var cached: Bool?
    public var fetchedAt: Date?
    public var note: String?
}

public struct StudiedApplication: Codable, Sendable, Equatable {
    public var application: String
    public var summary: String
    public var evidence: EvidenceAssessment
    public var citations: [Citation]
}

/// A Compound Insight Card. There is deliberately no single numeric score.
public struct CompoundInsightCard: Codable, Sendable, Equatable {
    public var name: String
    public var query: String
    /// "prescription", "otc", "hormone", "peptide_investigational", "vitamin_mineral", "supplement", "compounded",
    /// "exercise_rehab", "lifestyle", "nutrition", "clinician_procedure", "other"
    public var category: String
    public var mechanism: String
    public var studiedApplications: [StudiedApplication]
    public var evidence: EvidenceAssessment
    public var preclinicalFindings: String
    public var anecdotalReports: AnecdotalReports?
    public var risksUnknowns: [String]
    public var regulatoryStatus: RegulatoryStatus?
    public var contraindicationsInteractions: [InteractionFlag]
    public var interactionConsiderations: [String]
    public var establishedApproaches: [EstablishedApproach]
    public var comparisonToEstablished: String
    public var personalizedNote: String
    /// Always present: dosing is never provided.
    public var dosingNote: String
    public var citations: [Citation]
    public var sourcesChecked: [SourceCheck]
    public var droppedCitationIds: [String]
    public var guardApplied: [String]
    public var researchRetrievedAt: Date?
    public var lastVerifiedAt: Date?
    public var disclaimer: String

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func opt<T: Decodable>(_ k: CodingKeys, _ d: T) throws -> T { try c.decodeIfPresent(T.self, forKey: k) ?? d }
        name = try c.decode(String.self, forKey: .name)
        query = try opt(.query, name)
        category = try opt(.category, "other")
        mechanism = try opt(.mechanism, "")
        studiedApplications = try opt(.studiedApplications, [])
        evidence = try c.decode(EvidenceAssessment.self, forKey: .evidence)
        preclinicalFindings = try opt(.preclinicalFindings, "")
        anecdotalReports = try c.decodeIfPresent(AnecdotalReports.self, forKey: .anecdotalReports)
        risksUnknowns = try opt(.risksUnknowns, [])
        regulatoryStatus = try c.decodeIfPresent(RegulatoryStatus.self, forKey: .regulatoryStatus)
        contraindicationsInteractions = try opt(.contraindicationsInteractions, [])
        interactionConsiderations = try opt(.interactionConsiderations, [])
        establishedApproaches = try opt(.establishedApproaches, [])
        comparisonToEstablished = try opt(.comparisonToEstablished, "")
        personalizedNote = try opt(.personalizedNote, "")
        dosingNote = try opt(.dosingNote, "Dosing information is intentionally not provided.")
        citations = try opt(.citations, [])
        sourcesChecked = try opt(.sourcesChecked, [])
        droppedCitationIds = try opt(.droppedCitationIds, [])
        guardApplied = try opt(.guardApplied, [])
        researchRetrievedAt = try c.decodeIfPresent(Date.self, forKey: .researchRetrievedAt)
        lastVerifiedAt = try c.decodeIfPresent(Date.self, forKey: .lastVerifiedAt)
        disclaimer = try opt(.disclaimer, "Educational summary of published research, not medical advice.")
    }

    /// Citations grouped by source, for a "Sources" section.
    public var citationsBySource: [(Citation.Source, [Citation])] {
        [Citation.Source.pubmed, .clinicaltrials, .fdaLabel].compactMap { s in
            let cs = citations.filter { $0.source == s }
            return cs.isEmpty ? nil : (s, cs)
        }
    }
}

public enum TriageLevel: String, Codable, Sendable, Comparable {
    case none, seeClinician = "see_clinician", urgent, emergency
    var rank: Int { switch self { case .none: 0; case .seeClinician: 1; case .urgent: 2; case .emergency: 3 } }
    public static func < (l: TriageLevel, r: TriageLevel) -> Bool { l.rank < r.rank }
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = TriageLevel(rawValue: raw) ?? .seeClinician
    }
}

/// Deterministic red-flag triage result. When `stop` is true, no compound information was produced.
public struct TriageResult: Codable, Sendable, Equatable {
    public struct Flag: Codable, Sendable, Equatable, Hashable { public var id: String; public var label: String; public var level: TriageLevel }
    public var level: TriageLevel
    public var stop: Bool
    public var flags: [Flag]
    public var message: String
}

public struct DiscoverySuggestion: Codable, Sendable, Equatable, Identifiable {
    public var candidateId: String
    public var name: String
    public var category: String
    /// "non_drug" | "otc" | "prescription" | "supplement" | "clinician" | "followed_interest"
    public var kind: String
    public var reasonTags: [String]
    public var whyRelevant: String
    public var evidence: EvidenceAssessment
    public var cautions: [String]
    public var interactionFlags: [InteractionFlag]
    public var citations: [Citation]
    public var alreadyInRoutine: Bool
    public var summarizedByModel: Bool?

    public var id: String { candidateId }
    public var isNonDrug: Bool { kind == "non_drug" }
}

public struct SuggestedTopic: Codable, Sendable, Equatable, Hashable {
    public var name: String
    public var searchTerm: String
    public var category: String
    public var why: String
}

public struct ResearchInterest: Codable, Sendable, Equatable, Identifiable, Hashable {
    public enum Kind: String, Codable, Sendable { case compound, topic }
    public var id: UUID
    public var kind: Kind
    public var term: String
    public var displayName: String?
    public var createdAt: Date?
    public var lastCheckedAt: Date?

    public var title: String { displayName ?? term }
}

public struct ResearchAlert: Codable, Sendable, Equatable, Identifiable, Hashable {
    public var id: UUID
    public var interestId: UUID
    /// "new_meta_analysis" | "new_systematic_review" | "new_rct" | "fda_label_update" | "trial_results_posted" | "trial_completed"
    public var kind: String
    public var title: String
    public var summary: String
    public var citation: Citation?
    public var createdAt: Date?
    public var seenAt: Date?

    public var isSeen: Bool { seenAt != nil }

    public var kindDisplayName: String {
        switch kind {
        case "new_meta_analysis": "New meta-analysis"
        case "new_systematic_review": "New systematic review"
        case "new_rct": "New randomized trial"
        case "fda_label_update": "FDA label updated"
        case "trial_results_posted": "Trial results posted"
        case "trial_completed": "Trial completed"
        default: "Research update"
        }
    }

    /// Text for a local notification (no health data beyond the followed topic).
    public var notificationTitle: String { title }
    public var notificationBody: String { "\(summary)\nTap to review — new studies don't automatically change what's right for you." }
}

/// A card or discovery stored in `compound_insights` (read with RLS).
public struct SavedInsight: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    /// "card" | "discovery"
    public var kind: String
    public var compoundName: String
    public var evidenceLevel: EvidenceLevel?
    public var lastVerifiedAt: Date?
    public var createdAt: Date?
}

// MARK: - Responses

public struct InsightCardResponse: Decodable, Sendable {
    public var card: CompoundInsightCard?
    public var triage: TriageResult?
    /// True when red-flag triage stopped the request (card is nil).
    public var stopped: Bool?
    public var cached: Bool?
    public var insightId: UUID?
}

public struct DiscoverResponse: Decodable, Sendable {
    public var summary: String?
    public var suggestions: [DiscoverySuggestion]
    public var additionalTopics: [SuggestedTopic]?
    public var triage: TriageResult?
    public var stopped: Bool?
    public var cached: Bool?
    public var dosingNote: String?
    public var disclaimer: String?
    public var generatedAt: Date?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        suggestions = try c.decodeIfPresent([DiscoverySuggestion].self, forKey: .suggestions) ?? []
        additionalTopics = try c.decodeIfPresent([SuggestedTopic].self, forKey: .additionalTopics)
        triage = try c.decodeIfPresent(TriageResult.self, forKey: .triage)
        stopped = try c.decodeIfPresent(Bool.self, forKey: .stopped)
        cached = try c.decodeIfPresent(Bool.self, forKey: .cached)
        dosingNote = try c.decodeIfPresent(String.self, forKey: .dosingNote)
        disclaimer = try c.decodeIfPresent(String.self, forKey: .disclaimer)
        generatedAt = try c.decodeIfPresent(Date.self, forKey: .generatedAt)
    }
    private enum CodingKeys: String, CodingKey { case summary, suggestions, additionalTopics, triage, stopped, cached, dosingNote, disclaimer, generatedAt }

    /// Suggestions with non-drug options first within the same evidence level.
    public var nonDrugFirst: [DiscoverySuggestion] {
        suggestions.sorted { a, b in
            a.evidence.level != b.evidence.level ? a.evidence.level > b.evidence.level : (a.isNonDrug && !b.isNonDrug)
        }
    }
}

public struct CheckUpdatesResponse: Decodable, Sendable {
    public var alerts: [ResearchAlert]
    public var checked: Int
    public var checkedAt: Date?
}

// MARK: - Pure helpers

public enum ResearchAlertNotifier {
    /// Alerts that should produce a local notification: unseen and not notified before.
    public static func toNotify(_ alerts: [ResearchAlert], alreadyNotified: Set<UUID>) -> [ResearchAlert] {
        alerts.filter { !$0.isSeen && !alreadyNotified.contains($0.id) }
    }
}

// MARK: - Client

/// Talks to the `research` Edge Function and the research tables (PostgREST with the user's JWT,
/// so RLS applies). Errors are reported as `CoachError` so the app can reuse its coach error UI.
/// Online-only; nothing is queued offline.
public struct ResearchClient: Sendable {
    let config: SupabaseConfig
    let transport: any HTTPTransport
    let auth: SupabaseAuth

    public init(config: SupabaseConfig, transport: any HTTPTransport, auth: SupabaseAuth) {
        self.config = config; self.transport = transport; self.auth = auth
    }

    /// Compound Insight Card. Check `stopped`/`triage` first: red flags return triage advice only.
    public func insightCard(compound: String, question: String? = nil, forceRefresh: Bool = false) async throws -> InsightCardResponse {
        var b: [String: Any] = ["op": "insight_card", "compound": compound]
        if let question, !question.isEmpty { b["question"] = question }
        if forceRefresh { b["force_refresh"] = true }
        return try await call(b)
    }

    /// Proactive discovery from the user's goals, symptoms, measurements and routine.
    public func discover(concern: String? = nil, max: Int? = nil, forceRefresh: Bool = false, now: Date = Date(), timeZone: TimeZone = .current) async throws -> DiscoverResponse {
        var b: [String: Any] = ["op": "discover", "local_date": CoachDates.localDate(now, timeZone: timeZone)]
        if let concern, !concern.isEmpty { b["concern"] = concern }
        if let max { b["max"] = max }
        if forceRefresh { b["force_refresh"] = true }
        return try await call(b)
    }

    public func interests() async throws -> [ResearchInterest] {
        struct R: Decodable { var interests: [ResearchInterest] }
        let r: R = try await call(["op": "interests_list"])
        return r.interests
    }

    /// Follows a compound/topic (requires AI consent on the server). Returns the existing interest if already followed.
    public func addInterest(_ term: String, kind: ResearchInterest.Kind = .compound, displayName: String? = nil) async throws -> ResearchInterest {
        struct R: Decodable { var interest: ResearchInterest }
        var b: [String: Any] = ["op": "interests_add", "term": term, "kind": kind.rawValue]
        if let displayName { b["display_name"] = displayName }
        let r: R = try await call(b)
        return r.interest
    }

    @discardableResult
    public func removeInterest(_ id: UUID) async throws -> Bool {
        struct R: Decodable { var removed: Bool }
        let r: R = try await call(["op": "interests_remove", "id": id.uuidString.lowercased()])
        return r.removed
    }

    /// Checks followed topics for meaningful new evidence (rate-limited server-side to every 12 h per topic).
    /// Poll this (e.g. on app open / background refresh) and post local notifications for the returned alerts.
    public func checkUpdates(force: Bool = false) async throws -> CheckUpdatesResponse {
        var b: [String: Any] = ["op": "check_updates"]
        if force { b["force_refresh"] = true }
        return try await call(b)
    }

    // Tables (PostgREST, RLS-scoped)

    public func alerts(unseenOnly: Bool = false, limit: Int = 50) async throws -> [ResearchAlert] {
        var q: [(String, String)] = [("select", "id,interest_id,kind,title,summary,citation,created_at,seen_at"), ("order", "created_at.desc"), ("limit", "\(limit)")]
        if unseenOnly { q.append(("seen_at", "is.null")) }
        return try await get("research_alerts", q)
    }

    public func markAlertSeen(_ id: UUID, at date: Date = Date()) async throws {
        _ = try await rest("PATCH", "research_alerts", [("id", "eq.\(id.uuidString.lowercased())")],
                           body: try JSONSerialization.data(withJSONObject: ["seen_at": ISO8601.format(date)]))
    }

    public func deleteAlert(_ id: UUID) async throws {
        _ = try await rest("DELETE", "research_alerts", [("id", "eq.\(id.uuidString.lowercased())")], body: nil)
    }

    /// Previously generated cards (metadata only; open one with `savedCard(_:)`).
    public func savedCards(limit: Int = 50) async throws -> [SavedInsight] {
        try await get("compound_insights", [("select", "id,kind,compound_name,evidence_level,last_verified_at,created_at"), ("kind", "eq.card"),
                                            ("order", "created_at.desc"), ("limit", "\(limit)")])
    }

    public func savedCard(_ id: UUID) async throws -> CompoundInsightCard? {
        struct Row: Decodable { var payload: CompoundInsightCard }
        let rows: [Row] = try await get("compound_insights", [("select", "payload"), ("id", "eq.\(id.uuidString.lowercased())")])
        return rows.first?.payload
    }

    public func deleteSavedCard(_ id: UUID) async throws {
        _ = try await rest("DELETE", "compound_insights", [("id", "eq.\(id.uuidString.lowercased())")], body: nil)
    }

    // Plumbing

    func call<T: Decodable>(_ body: [String: Any]) async throws -> T {
        var req = URLRequest(url: config.url.appending(path: "functions/v1/research"))
        req.httpMethod = "POST"
        req.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        req.timeoutInterval = 120
        try await authorize(&req)
        let (data, resp) = try await sendMapped(req)
        let ok = try Self.mapStatus(data, resp)
        do { return try VitalJSON.decoder().decode(T.self, from: ok) } catch { throw CoachError.badResponse }
    }

    static func mapStatus(_ data: Data, _ resp: HTTPURLResponse) throws -> Data {
        if (200..<300).contains(resp.statusCode) { return data }
        struct E: Decodable { var error: String?; var message: String? }
        let e = (try? JSONDecoder().decode(E.self, from: data)) ?? E(error: nil, message: nil)
        let message = e.message ?? "Research isn't available right now. Please try again."
        switch (resp.statusCode, e.error) {
        case (401, _): throw CoachError.unauthorized
        case (403, "consent_required"): throw CoachError.consentRequired(message)
        case (429, let code): throw CoachError.limitReached(code: code ?? "limit", message: message)
        case (503, "coach_not_configured"): throw CoachError.notConfigured(message)
        case (404, _): throw CoachError.notConfigured("The research service isn't deployed yet.")
        default: throw CoachError.unavailable(message)
        }
    }

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
        default: throw CoachError.unavailable("Couldn't update research right now (HTTP \(resp.statusCode)).")
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
