import Foundation

// MARK: - Catalog model

/// One verified entry in the bundled substance catalog. Entries are curated by hand from public
/// reference sources (see `SubstanceCatalog.sources`) and reviewed in pull requests. Nothing in
/// the catalog is generated at runtime, and user-created names are never added to it.
public struct CatalogEntry: Codable, Sendable, Hashable, Identifiable {
    /// Stable slug, e.g. "metformin". Never reused for a different substance.
    public var id: String
    /// Preferred display name (generic / INN name where one exists).
    public var name: String
    /// Categories this entry appears under. The first one is the primary category.
    public var categories: [SubstanceCategory]
    /// Brand names, abbreviations, common synonyms and alternative spellings.
    public var aliases: [String]
    /// Typical routes for the products sold under this name. Only used to pre-select a route
    /// when there is exactly one; the user always confirms it.
    public var routes: [AdministrationRoute]
    /// The unit products are usually labelled in. A hint for the unit picker, never a dose.
    public var unitHint: DoseUnit?
    /// Relative familiarity (0–100) used only to order equally good matches.
    public var popularity: Int
    /// Short factual note shown in search results (e.g. "Investigational · not FDA-approved").
    public var note: String?

    public init(id: String, name: String, categories: [SubstanceCategory], aliases: [String] = [],
                routes: [AdministrationRoute] = [], unitHint: DoseUnit? = nil, popularity: Int = 50, note: String? = nil) {
        self.id = id; self.name = name; self.categories = categories; self.aliases = aliases
        self.routes = routes; self.unitHint = unitHint; self.popularity = popularity; self.note = note
    }

    public var primaryCategory: SubstanceCategory { categories.first ?? .other }

    /// A route to pre-select, only when the catalog lists exactly one (an oral tablet never
    /// defaults to injection; a product sold in several forms has no default).
    public var defaultRoute: AdministrationRoute? { routes.count == 1 ? routes[0] : nil }
}

/// A substance name the user typed that isn't in the catalog. Stored on the device only,
/// separately from the verified catalog, and always shown as user-created.
public struct CustomSubstance: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var category: SubstanceCategory
    public var alternateName: String?
    public var notes: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), name: String, category: SubstanceCategory, alternateName: String? = nil,
                notes: String? = nil, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id; self.name = name; self.category = category; self.alternateName = alternateName
        self.notes = notes; self.createdAt = createdAt; self.updatedAt = updatedAt
    }
}

/// One autocomplete row.
public struct SubstanceSuggestion: Sendable, Hashable, Identifiable {
    public enum Source: Sendable, Hashable {
        case verified(CatalogEntry)
        case custom(CustomSubstance)
    }

    public var source: Source
    /// Set when the query matched a brand name or synonym rather than the display name,
    /// so the row can say "Glucophage → Metformin".
    public var matchedAlias: String?

    public init(source: Source, matchedAlias: String? = nil) {
        self.source = source; self.matchedAlias = matchedAlias
    }

    public var id: String {
        switch source {
        case .verified(let e): "catalog:\(e.id)"
        case .custom(let c): "custom:\(c.id.uuidString.lowercased())"
        }
    }

    public var name: String {
        switch source {
        case .verified(let e): e.name
        case .custom(let c): c.name
        }
    }

    public var isUserCreated: Bool {
        if case .custom = source { return true }
        return false
    }

    public var catalogEntry: CatalogEntry? {
        if case .verified(let e) = source { return e }
        return nil
    }

    /// Value stored in `UserSubstance.catalogRef` so a routine remembers where its name came from.
    public var catalogRef: String {
        switch source {
        case .verified(let e): "catalog:\(e.id)@\(SubstanceCatalog.version)"
        case .custom(let c): "custom:\(c.id.uuidString.lowercased())"
        }
    }
}

// MARK: - Custom substance storage

public protocol CustomSubstanceStore: Sendable {
    func load() async throws -> [CustomSubstance]
    func save(_ all: [CustomSubstance]) async throws
}

public actor InMemoryCustomSubstanceStore: CustomSubstanceStore {
    private var items: [CustomSubstance]
    public var failNextLoad = false
    public init(_ items: [CustomSubstance] = []) { self.items = items }
    public func setFailNextLoad(_ v: Bool) { failNextLoad = v }
    public func load() async throws -> [CustomSubstance] {
        if failNextLoad { failNextLoad = false; throw CocoaError(.fileReadUnknown) }
        return items
    }
    public func save(_ all: [CustomSubstance]) async throws { items = all }
}

/// JSON file on the device (Application Support on iOS). Written atomically and, on iOS,
/// with complete file protection. Not part of cloud sync: custom names stay on this iPhone
/// (the routine that uses one syncs as usual).
public actor FileCustomSubstanceStore: CustomSubstanceStore {
    private let url: URL

    public init(url: URL) { self.url = url }

    public func load() async throws -> [CustomSubstance] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        return try VitalJSON.decoder().decode([CustomSubstance].self, from: data)
    }

    public func save(_ all: [CustomSubstance]) async throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try VitalJSON.encoder().encode(all)
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: url, options: .atomic)
        #endif
    }
}

// MARK: - Search

/// Text normalisation shared by indexing and queries: lower-case, diacritics folded,
/// punctuation and spaces removed for the compact form ("BPC-157" → "bpc157").
public enum SearchText {
    public static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
    }

    public static func compact(_ s: String) -> String {
        String(fold(s).unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    public static func words(_ s: String) -> [String] {
        fold(s).split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    /// Optimal-string-alignment distance (Levenshtein plus adjacent transpositions).
    public static func distance(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var d = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0...a.count { d[i][0] = i }
        for j in 0...b.count { d[0][j] = j }
        for i in 1...a.count {
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1)
                }
            }
        }
        return d[a.count][b.count]
    }
}

/// Match quality, best first.
enum MatchTier: Int, Comparable {
    case exactName = 0, namePrefix, exactAlias, aliasPrefix, wordPrefix, substring, fuzzy
    static func < (l: MatchTier, r: MatchTier) -> Bool { l.rawValue < r.rawValue }
}

/// Pre-normalised search terms for one entry (built once and cached).
struct IndexedTerms: Sendable {
    struct Term: Sendable {
        var original: String
        var isName: Bool
        var compact: String
        var compactChars: [Character]
        var words: [String]
    }
    var terms: [Term]

    init(name: String, aliases: [String]) {
        terms = ([(name, true)] + aliases.map { ($0, false) }).map { s, isName in
            let c = SearchText.compact(s)
            return Term(original: s, isName: isName, compact: c, compactChars: Array(c), words: SearchText.words(s))
        }
    }

    /// Best tier for the query, and the alias that produced it (nil when the display name matched).
    func match(compactQuery q: String, queryWords: [String]) -> (MatchTier, String?)? {
        guard !q.isEmpty else { return nil }
        let qChars = Array(q)
        var best: (MatchTier, String?)?
        func consider(_ tier: MatchTier, _ term: Term) {
            if best == nil || tier < best!.0 { best = (tier, term.isName ? nil : term.original) }
        }
        for t in terms {
            if t.compact == q { consider(t.isName ? .exactName : .exactAlias, t); continue }
            if t.compact.hasPrefix(q) { consider(t.isName ? .namePrefix : .aliasPrefix, t); continue }
            if let first = queryWords.first, t.words.contains(where: { $0.hasPrefix(first) }),
               queryWords.dropFirst().allSatisfy({ w in t.words.contains { $0.hasPrefix(w) } }) {
                consider(.wordPrefix, t); continue
            }
            if q.count >= 3, t.compact.contains(q) { consider(.substring, t); continue }
            if q.count >= 5 {
                // Typo tolerance: compare against the term's prefix of about the query's length.
                let allowed = q.count >= 8 ? 2 : 1
                var bestDistance = Int.max
                for len in max(1, q.count - 1)...(q.count + 1) where len <= t.compactChars.count {
                    bestDistance = min(bestDistance, SearchText.distance(qChars, Array(t.compactChars.prefix(len))))
                }
                if bestDistance <= allowed { consider(.fuzzy, t) }
            }
        }
        return best
    }
}

/// Category-filtered autocomplete over the verified catalog plus the user's own custom names.
///
/// - Search runs entirely on the device against a bundled catalog, so it works offline and
///   never sends what the user types anywhere.
/// - It never throws: if custom names can't be loaded, verified results are still returned, and
///   the UI always offers manual entry.
public actor SubstanceAutocompleteService {
    private let catalog: [CatalogEntry]
    private let index: [IndexedTerms]
    private let store: CustomSubstanceStore
    private var custom: [CustomSubstance]?
    private var cache: [String: [SubstanceSuggestion]] = [:]

    public init(catalog: [CatalogEntry] = SubstanceCatalog.entries, customStore: CustomSubstanceStore) {
        self.catalog = catalog
        self.index = catalog.map { IndexedTerms(name: $0.name, aliases: $0.aliases) }
        self.store = customStore
    }

    /// Results for `query`, best first, without duplicates. 1–2 character queries match only
    /// name/alias/word starts; typo tolerance applies from 5 characters (two typos from 8).
    public func search(_ query: String, category: SubstanceCategory?, limit: Int = 20) async -> [SubstanceSuggestion] {
        let q = SearchText.compact(query)
        guard !q.isEmpty else { return [] }
        let key = "\(category?.rawValue ?? "*")|\(q)|\(limit)"
        if let hit = cache[key] { return hit }

        let words = SearchText.words(query)
        let shortQuery = q.count <= 2
        typealias Scored = (tier: MatchTier, verified: Bool, popularity: Int, suggestion: SubstanceSuggestion)
        var scored: [Scored] = []

        for (i, entry) in catalog.enumerated() {
            if let category, !entry.categories.contains(category) { continue }
            guard let (tier, alias) = index[i].match(compactQuery: q, queryWords: words) else { continue }
            if shortQuery && tier > .wordPrefix { continue }
            scored.append((tier, true, entry.popularity, SubstanceSuggestion(source: .verified(entry), matchedAlias: alias)))
        }

        for c in await customSubstances() {
            if let category, c.category != category { continue }
            let terms = IndexedTerms(name: c.name, aliases: [c.alternateName].compactMap { $0 })
            guard let (tier, alias) = terms.match(compactQuery: q, queryWords: words) else { continue }
            if shortQuery && tier > .wordPrefix { continue }
            scored.append((tier, false, 0, SubstanceSuggestion(source: .custom(c), matchedAlias: alias)))
        }

        scored.sort { a, b in
            if a.tier != b.tier { return a.tier < b.tier }
            if a.verified != b.verified { return a.verified }
            if a.popularity != b.popularity { return a.popularity > b.popularity }
            if a.suggestion.name.count != b.suggestion.name.count { return a.suggestion.name.count < b.suggestion.name.count }
            return a.suggestion.name < b.suggestion.name
        }

        var seen = Set<String>()
        var seenNames = Set<String>()
        var out: [SubstanceSuggestion] = []
        for s in scored {
            let nameKey = SearchText.compact(s.suggestion.name)
            guard seen.insert(s.suggestion.id).inserted else { continue }
            // A custom entry spelled exactly like a verified one adds nothing.
            if s.suggestion.isUserCreated, seenNames.contains(nameKey) { continue }
            seenNames.insert(nameKey)
            out.append(s.suggestion)
            if out.count == limit { break }
        }
        cache[key] = out
        return out
    }

    /// `search` after a short pause; returns nil if the calling task was cancelled meanwhile
    /// (the user kept typing). Use from `.task(id: query)` in SwiftUI.
    public func debouncedSearch(_ query: String, category: SubstanceCategory?, delay: Duration = .milliseconds(150),
                                limit: Int = 20) async -> [SubstanceSuggestion]? {
        try? await Task.sleep(for: delay)
        if Task.isCancelled { return nil }
        return await search(query, category: category, limit: limit)
    }

    /// Whether a verified entry already has exactly this name or alias in the category.
    public func exactVerifiedMatch(_ name: String, category: SubstanceCategory) -> CatalogEntry? {
        let q = SearchText.compact(name)
        for (i, e) in catalog.enumerated() where e.categories.contains(category) {
            if index[i].terms.contains(where: { $0.compact == q }) { return e }
        }
        return nil
    }

    // MARK: Custom substances

    public func customSubstances() async -> [CustomSubstance] {
        if let custom { return custom }
        let loaded = (try? await store.load()) ?? []
        // Don't memoise a failed load as "none": try again next time.
        if !loaded.isEmpty { custom = loaded }
        return loaded
    }

    public enum CustomError: Error, Equatable { case emptyName, nameTooLong }

    /// Saves a user-created name. Re-adding the same name in the same category returns the
    /// existing entry instead of creating a duplicate.
    @discardableResult
    public func addCustom(name: String, category: SubstanceCategory, alternateName: String? = nil,
                          notes: String? = nil, now: Date = Date()) async throws -> CustomSubstance {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CustomError.emptyName }
        guard trimmed.count <= 200 else { throw CustomError.nameTooLong }
        var all = await customSubstances()
        let key = SearchText.compact(trimmed)
        if let existing = all.first(where: { SearchText.compact($0.name) == key && $0.category == category }) {
            return existing
        }
        let item = CustomSubstance(name: trimmed, category: category, alternateName: alternateName.nilIfEmptyTrimmed,
                                   notes: notes.nilIfEmptyTrimmed, createdAt: now, updatedAt: now)
        all.append(item)
        try await store.save(all)
        custom = all
        cache.removeAll()
        return item
    }

    public func updateCustom(_ item: CustomSubstance, now: Date = Date()) async throws {
        var all = await customSubstances()
        guard let i = all.firstIndex(where: { $0.id == item.id }) else { return }
        let trimmed = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CustomError.emptyName }
        var updated = item
        updated.name = trimmed
        updated.alternateName = item.alternateName.nilIfEmptyTrimmed
        updated.notes = item.notes.nilIfEmptyTrimmed
        updated.updatedAt = now
        all[i] = updated
        try await store.save(all)
        custom = all
        cache.removeAll()
    }

    public func deleteCustom(id: UUID) async throws {
        var all = await customSubstances()
        all.removeAll { $0.id == id }
        try await store.save(all)
        custom = all
        cache.removeAll()
    }
}

private extension Optional where Wrapped == String {
    var nilIfEmptyTrimmed: String? {
        guard let s = self?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }
}
