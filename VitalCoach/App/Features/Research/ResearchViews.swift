import SwiftUI
import VitalCore

// MARK: - Evidence badge

extension EvidenceLevel {
    var symbolName: String {
        switch self {
        case .established, .moderate: "person.3.fill"
        case .preliminary: "person.2"
        case .preclinicalAnimal: "pawprint"
        case .inVitro: "testtube.2"
        case .anecdotal: "text.bubble"
        case .insufficient: "questionmark.circle"
        }
    }

    /// Stronger human evidence is shown in teal; weaker or non-human evidence in caution colours.
    /// The label always carries the meaning; colour only supports it.
    var tint: Color {
        switch self {
        case .established, .moderate: VitalColors.success
        case .preliminary: VitalColors.info
        case .preclinicalAnimal, .inVitro, .anecdotal: VitalColors.caution
        case .insufficient: VitalColors.textSecondary
        }
    }
}

struct EvidenceBadge: View {
    var level: EvidenceLevel

    var body: some View {
        Label(level.displayName, systemImage: level.symbolName)
            .vitalFont(.caption)
            .foregroundStyle(level.tint)
            .padding(.horizontal, VitalSpacing.xs)
            .padding(.vertical, VitalSpacing.xxs)
            .background(level.tint.opacity(0.12), in: Capsule())
            .accessibilityLabel("Evidence: \(level.displayName)")
    }
}

/// The seven evidence levels, strongest first, for the "what do these mean" sheet.
struct EvidenceScaleView: View {
    var body: some View {
        List {
            Section {
                ForEach(EvidenceLevel.allCases.sorted(by: >), id: \.self) { level in
                    VStack(alignment: .leading, spacing: VitalSpacing.xxs) {
                        EvidenceBadge(level: level)
                        Text(level.explanation).vitalFont(.secondary).foregroundStyle(VitalColors.textSecondary)
                    }
                    .padding(.vertical, VitalSpacing.xxs)
                }
            } footer: {
                Text("VitalCoach never reduces evidence to a single score. A level can only be as strong as the studies actually retrieved for it; if the AI claims more, the level is lowered automatically.")
            }
            .vitalRow()
        }
        .vitalListBackground()
        .navigationTitle("Evidence levels")
    }
}

// MARK: - Research hub (inside the Coach tab)

struct ResearchHubSection: View {
    @Environment(AppModel.self) var model

    var body: some View {
        Section {
            NavigationLink { CompoundLookupView() } label: {
                Label("Look up a compound or intervention", systemImage: "magnifyingglass")
            }
            .accessibilityIdentifier("research.lookup")
            NavigationLink { DiscoverView() } label: {
                Label("Options for my goals", systemImage: "lightbulb")
            }
            .accessibilityIdentifier("research.discover")
            NavigationLink { FollowedResearchView() } label: {
                HStack {
                    Label("Followed research & alerts", systemImage: "bell.badge")
                    Spacer()
                    if model.unseenResearchAlerts > 0 {
                        Text("\(model.unseenResearchAlerts)")
                            .vitalFont(.caption).monospacedDigit()
                            .foregroundStyle(VitalColors.onAccent)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(VitalColors.accentStrong, in: Capsule())
                            .accessibilityLabel("\(model.unseenResearchAlerts) new")
                    }
                }
            }
            NavigationLink { EvidenceScaleView() } label: {
                Label("How evidence is rated", systemImage: "list.number")
            }
        } header: {
            Text("Research")
        } footer: {
            Text("Summaries of published research with citations, checked against your routine. Educational only: no dosing, and nothing here replaces your clinician.")
        }
        .vitalRow()
    }
}

struct CompoundLookupView: View {
    @State private var query = ""
    @State private var question = ""
    @State private var submitted: String?

    var body: some View {
        Form {
            Section {
                TextField("Compound or intervention (e.g. BPC-157, creatine, PT)", text: $query)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.search)
                    .onSubmit(open)
                    .accessibilityIdentifier("research.query")
                TextField("Your question (optional)", text: $question, axis: .vertical)
                    .lineLimit(1...3)
                Button("Show research card", action: open)
                    .buttonStyle(VitalButtonStyle(kind: .primary))
                    .disabled(query.nilIfBlank == nil)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            } footer: {
                Text("Only the compound name and topic are sent to PubMed, ClinicalTrials.gov and FDA. Your health data isn't.")
            }
            .vitalRow()
        }
        .vitalListBackground()
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Research lookup")
        .navigationDestination(item: $submitted) { compound in
            InsightCardView(compound: compound, question: question.nilIfBlank)
        }
    }

    private func open() {
        guard let q = query.nilIfBlank else { return }
        submitted = String(q.prefix(120))
    }
}

// MARK: - Insight card

struct InsightCardView: View {
    @Environment(AppModel.self) var model
    var compound: String
    var question: String?

    @State private var response: InsightCardResponse?
    @State private var errorText: String?
    @State private var loading = false
    @State private var followed = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: VitalSpacing.m) {
                if loading && response == nil {
                    VitalLoadingState(text: "Checking published research for \(compound)…")
                }
                if let errorText { NoticeBanner(style: .warning, text: errorText) }
                if let r = response {
                    if r.stopped == true || r.card == nil, let triage = r.triage {
                        TriageCard(triage: triage)
                    } else if let card = r.card {
                        if let triage = r.triage, triage.level != .none { TriageCard(triage: triage) }
                        CardBody(card: card, followed: followed, onFollow: { Task { await follow(card) } })
                    }
                }
            }
            .padding(.horizontal, VitalSpacing.page)
            .padding(.vertical, VitalSpacing.m)
        }
        .vitalScreenBackground()
        .navigationTitle(compound)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await load(force: true) } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .disabled(loading)
            }
        }
        .refreshable { await load(force: true) }
        .task { if response == nil { await load(force: false) } }
    }

    private func load(force: Bool) async {
        guard let research = model.research else { errorText = "Research needs an account with AI coaching turned on."; return }
        loading = true
        defer { loading = false }
        errorText = nil
        await model.syncNow()
        do {
            response = try await research.insightCard(compound: compound, question: question, forceRefresh: force)
        } catch let e as CoachError {
            errorText = e.userMessage
        } catch {
            errorText = "Couldn't load research. Check your connection and try again."
        }
    }

    private func follow(_ card: CompoundInsightCard) async {
        guard let research = model.research else { return }
        do {
            _ = try await research.addInterest(card.query, kind: .compound, displayName: card.name)
            followed = true
        } catch let e as CoachError {
            errorText = e.userMessage
        } catch {
            errorText = "Couldn't follow this topic. Please try again."
        }
    }
}

struct TriageCard: View {
    var triage: TriageResult

    var body: some View {
        VitalCard {
            Label(title, systemImage: triage.level >= .urgent ? "cross.case.fill" : "stethoscope")
                .vitalFont(.cardTitle)
                .foregroundStyle(triage.level >= .urgent ? VitalColors.critical : VitalColors.caution)
                .accessibilityAddTraits(.isHeader)
            Text(triage.message).vitalFont(.body).foregroundStyle(VitalColors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if !triage.flags.isEmpty {
                ForEach(triage.flags, id: \.self) { f in
                    Label(f.label, systemImage: "exclamationmark.circle")
                        .vitalFont(.secondary).foregroundStyle(VitalColors.textSecondary)
                }
            }
        }
    }

    private var title: String {
        switch triage.level {
        case .emergency: "Get emergency care now"
        case .urgent: "Get checked urgently"
        case .seeClinician: "Worth seeing a clinician first"
        case .none: "Before you go further"
        }
    }
}

private struct CardBody: View {
    var card: CompoundInsightCard
    var followed: Bool
    var onFollow: () -> Void
    @State private var showingScale = false

    var body: some View {
        header
        safety
        research
        sources
    }

    @ViewBuilder private var header: some View {
        VitalCard(style: .featured, padding: VitalSpacing.l) {
            Text(card.category.uppercased()).vitalFont(.caption).tracking(0.8).foregroundStyle(VitalColors.accentStrong)
            Text(card.name).vitalFont(.section).foregroundStyle(VitalColors.textPrimary).accessibilityAddTraits(.isHeader)
            HStack(spacing: VitalSpacing.xs) {
                EvidenceBadge(level: card.evidence.level)
                Button { showingScale = true } label: { Image(systemName: "info.circle") }
                    .accessibilityLabel("What evidence levels mean")
                    .frame(minWidth: VitalMetrics.minTouchTarget, minHeight: VitalMetrics.minTouchTarget)
            }
            Text(card.evidence.displayExplanation).vitalFont(.secondary).foregroundStyle(VitalColors.textPrimary)
            if card.evidence.capped, let reason = card.evidence.capReason {
                Label("Level lowered: \(reason)", systemImage: "arrow.down.circle")
                    .vitalFont(.caption).foregroundStyle(VitalColors.caution)
            }
            if !card.personalizedNote.isEmpty {
                Text(card.personalizedNote).vitalFont(.body).foregroundStyle(VitalColors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VitalButton(title: followed ? "Following" : "Follow new research", systemImage: followed ? "checkmark" : "bell",
                        kind: .secondary, action: onFollow)
                .disabled(followed)
        }
        .sheet(isPresented: $showingScale) { NavigationStack { EvidenceScaleView() } }
    }

    @ViewBuilder private var safety: some View {
        // Dosing — always stated, never provided.
        NoticeBanner(style: .info, text: card.dosingNote.isEmpty
                     ? "VitalCoach doesn't provide doses, schedules or cycles. Dosing decisions belong with your clinician."
                     : card.dosingNote)

        if !card.contraindicationsInteractions.isEmpty || !card.interactionConsiderations.isEmpty {
            section("With your routine & conditions", "exclamationmark.triangle") {
                ForEach(card.contraindicationsInteractions, id: \.self) { f in
                    VStack(alignment: .leading, spacing: 2) {
                        Label("\(f.with): \(f.severityDisplayName)", systemImage: f.severity == "avoid_unless_clinician_approves" ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                            .vitalFont(.secondary).fontWeight(.semibold)
                            .foregroundStyle(f.severity == "avoid_unless_clinician_approves" ? VitalColors.critical : VitalColors.caution)
                        Text(f.detail).vitalFont(.secondary).foregroundStyle(VitalColors.textPrimary)
                    }
                }
                bullets(card.interactionConsiderations)
            }
        }

    }

    @ViewBuilder private var research: some View {
        if !card.mechanism.isEmpty {
            section("How it's thought to work", "gearshape.2") { paragraph(card.mechanism) }
        }

        if !card.studiedApplications.isEmpty {
            section("What it has been studied for", "doc.text.magnifyingglass") {
                ForEach(Array(card.studiedApplications.enumerated()), id: \.offset) { _, app in
                    VStack(alignment: .leading, spacing: VitalSpacing.xxs) {
                        Text(app.application).vitalFont(.cardTitle).foregroundStyle(VitalColors.textPrimary)
                        EvidenceBadge(level: app.evidence.level)
                        paragraph(app.summary)
                        ForEach(app.citations) { c in CitationRow(citation: c) }
                    }
                    .padding(.vertical, VitalSpacing.xxs)
                }
            }
        }

        if !card.preclinicalFindings.isEmpty {
            section("Animal and lab findings", "pawprint") {
                paragraph(card.preclinicalFindings)
                Text("Results in animals or cells often don't carry over to people.")
                    .vitalFont(.caption).foregroundStyle(VitalColors.textSecondary)
            }
        }

        if let a = card.anecdotalReports {
            section("Community reports", "text.bubble") {
                VitalStatusIndicator(status: .caution, text: a.label.isEmpty ? "Unverified" : a.label)
                paragraph(a.summary)
                if !a.biases.isEmpty {
                    Text("Why these reports are unreliable").vitalFont(.secondary).fontWeight(.semibold).foregroundStyle(VitalColors.textPrimary)
                    ForEach(a.biases, id: \.self) { b in
                        Text("• **\(b.name):** \(b.explanation)").vitalFont(.secondary).foregroundStyle(VitalColors.textSecondary)
                    }
                }
            }
        }

        if !card.risksUnknowns.isEmpty {
            section("Risks and unknowns", "exclamationmark.shield") { bullets(card.risksUnknowns) }
        }

    }

    @ViewBuilder private var sources: some View {
        if let reg = card.regulatoryStatus {
            section("Regulatory status", "building.columns") {
                Text(reg.fdaDisplayName).vitalFont(.secondary).fontWeight(.semibold).foregroundStyle(VitalColors.textPrimary)
                paragraph(reg.summary)
                if let w = reg.wada {
                    Text("Sport (WADA): \(w.status)\(w.note.map { " — \($0)" } ?? "")")
                        .vitalFont(.caption).foregroundStyle(VitalColors.textSecondary)
                }
            }
        }

        if !card.establishedApproaches.isEmpty || !card.comparisonToEstablished.isEmpty {
            section("Compared with established approaches", "checkmark.seal") {
                ForEach(card.establishedApproaches, id: \.self) { e in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(e.name).vitalFont(.secondary).fontWeight(.semibold).foregroundStyle(VitalColors.textPrimary)
                        Text(e.note).vitalFont(.secondary).foregroundStyle(VitalColors.textSecondary)
                    }
                }
                if !card.comparisonToEstablished.isEmpty { paragraph(card.comparisonToEstablished) }
            }
        }

        section("Sources", "books.vertical") {
            if card.citations.isEmpty {
                Text("No studies were retrieved for this topic, so no claims are made from research.")
                    .vitalFont(.secondary).foregroundStyle(VitalColors.textSecondary)
            }
            ForEach(Array(card.citationsBySource.enumerated()), id: \.offset) { _, group in
                Text(group.0.displayName).vitalFont(.caption).foregroundStyle(VitalColors.textSecondary)
                ForEach(group.1) { c in CitationRow(citation: c) }
            }
            if let verified = card.lastVerifiedAt ?? card.researchRetrievedAt {
                Label("Research retrieved \(verified.formatted(date: .abbreviated, time: .omitted))", systemImage: "clock")
                    .vitalFont(.caption).foregroundStyle(VitalColors.textSecondary)
            }
            let failed = card.sourcesChecked.filter { !$0.ok }
            if !failed.isEmpty {
                Text("Couldn't reach: \(failed.map(\.source.displayName).joined(separator: ", ")). Results may be incomplete.")
                    .vitalFont(.caption).foregroundStyle(VitalColors.caution)
            }
        }

        Text(card.disclaimer).vitalFont(.caption).foregroundStyle(VitalColors.textSecondary)
    }

    private func section<C: View>(_ title: String, _ icon: String, @ViewBuilder content: () -> C) -> some View {
        Card(title: title, systemImage: icon) { content() }
    }

    private func paragraph(_ text: String) -> some View {
        Text(text).vitalFont(.body).foregroundStyle(VitalColors.textPrimary).fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func bullets(_ items: [String]) -> some View {
        ForEach(items, id: \.self) { item in
            Text("• \(item)").vitalFont(.body).foregroundStyle(VitalColors.textPrimary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct CitationRow: View {
    var citation: Citation

    var body: some View {
        Group {
            if let link = citation.link {
                Link(destination: link) { content }
            } else {
                content
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(citation.title).vitalFont(.secondary).foregroundStyle(VitalColors.accentStrong).multilineTextAlignment(.leading)
            Text([citation.studyKindLabel, citation.year.map(String.init), "\(citation.source.displayName) \(citation.id)"]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                .vitalFont(.caption).foregroundStyle(VitalColors.textSecondary)
        }
        .frame(maxWidth: .infinity, minHeight: VitalMetrics.minTouchTarget, alignment: .leading)
    }
}

// MARK: - Discover

struct DiscoverView: View {
    @Environment(AppModel.self) var model
    @State private var concern = ""
    @State private var response: DiscoverResponse?
    @State private var loading = false
    @State private var errorText: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: VitalSpacing.m) {
                VitalTextField(label: "Anything specific? (optional)", text: $concern, prompt: "e.g. knee pain after running")
                VitalButton(title: response == nil ? "Find options" : "Update", systemImage: "lightbulb", isLoading: loading) {
                    Task { await load(force: response != nil) }
                }
                if let errorText { NoticeBanner(style: .warning, text: errorText) }
                if let r = response {
                    if r.stopped == true, let triage = r.triage {
                        TriageCard(triage: triage)
                    } else {
                        if let triage = r.triage, triage.level != .none { TriageCard(triage: triage) }
                        if let summary = r.summary, !summary.isEmpty {
                            VitalInsightCard(eyebrow: "Based on your goals and data", title: "Options to discuss", message: summary)
                        }
                        ForEach(r.nonDrugFirst) { s in SuggestionCard(suggestion: s) }
                        if let topics = r.additionalTopics, !topics.isEmpty {
                            VitalSectionHeader(title: "Also worth reading about")
                            ForEach(topics, id: \.self) { t in
                                NavigationLink { InsightCardView(compound: t.searchTerm, question: nil) } label: {
                                    VitalCard {
                                        Text(t.name).vitalFont(.cardTitle).foregroundStyle(VitalColors.textPrimary)
                                        Text(t.why).vitalFont(.secondary).foregroundStyle(VitalColors.textSecondary)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        NoticeBanner(style: .info, text: r.dosingNote ?? "VitalCoach doesn't provide doses. Bring anything here to your clinician before starting.")
                        if let d = r.disclaimer { Text(d).vitalFont(.caption).foregroundStyle(VitalColors.textSecondary) }
                    }
                } else if !loading {
                    Text("VitalCoach looks at your goals, check-ins, measurements and routine, then lists options that have been studied for them, including non-drug approaches, each with its evidence level and sources.")
                        .vitalFont(.secondary).foregroundStyle(VitalColors.textSecondary)
                }
            }
            .padding(.horizontal, VitalSpacing.page)
            .padding(.vertical, VitalSpacing.m)
        }
        .scrollDismissesKeyboard(.interactively)
        .vitalScreenBackground()
        .navigationTitle("Options for my goals")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func load(force: Bool) async {
        guard let research = model.research else { errorText = "Research needs an account with AI coaching turned on."; return }
        loading = true
        defer { loading = false }
        errorText = nil
        await model.syncNow()
        do {
            response = try await research.discover(concern: concern.nilIfBlank, forceRefresh: force)
        } catch let e as CoachError {
            errorText = e.userMessage
        } catch {
            errorText = "Couldn't load suggestions. Check your connection and try again."
        }
    }
}

private struct SuggestionCard: View {
    var suggestion: DiscoverySuggestion

    var body: some View {
        NavigationLink { InsightCardView(compound: suggestion.name, question: nil) } label: {
            VitalCard {
                HStack(alignment: .firstTextBaseline) {
                    Text(suggestion.name).vitalFont(.cardTitle).foregroundStyle(VitalColors.textPrimary)
                    Spacer()
                    if suggestion.isNonDrug {
                        VitalStatusIndicator(status: .info, text: "Non-drug", compact: true)
                    }
                    if suggestion.alreadyInRoutine {
                        VitalStatusIndicator(status: .neutral, text: "In your routine", compact: true)
                    }
                }
                EvidenceBadge(level: suggestion.evidence.level)
                Text(suggestion.whyRelevant).vitalFont(.secondary).foregroundStyle(VitalColors.textPrimary)
                    .multilineTextAlignment(.leading)
                ForEach(suggestion.interactionFlags, id: \.self) { f in
                    Label("\(f.with): \(f.severityDisplayName)", systemImage: "exclamationmark.triangle.fill")
                        .vitalFont(.caption).foregroundStyle(VitalColors.caution)
                }
                ForEach(suggestion.cautions, id: \.self) { c in
                    Text("• \(c)").vitalFont(.caption).foregroundStyle(VitalColors.textSecondary)
                }
                Label("\(suggestion.citations.count) source\(suggestion.citations.count == 1 ? "" : "s") · Open research card", systemImage: "chevron.right")
                    .labelStyle(.titleOnly)
                    .vitalFont(.caption).foregroundStyle(VitalColors.accentStrong)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Followed topics & alerts

struct FollowedResearchView: View {
    @Environment(AppModel.self) var model
    @State private var interests: [ResearchInterest] = []
    @State private var alerts: [ResearchAlert] = []
    @State private var saved: [SavedInsight] = []
    @State private var newTerm = ""
    @State private var errorText: String?

    var body: some View {
        List {
            if let errorText { Section { NoticeBanner(style: .warning, text: errorText) }.vitalRow() }
            Section {
                if alerts.isEmpty {
                    Text("No new research alerts. You're notified only about meaningful new evidence: new trials with results, systematic reviews or meta-analyses, and FDA label changes.")
                        .vitalFont(.secondary).foregroundStyle(VitalColors.textSecondary)
                }
                ForEach(alerts) { a in
                    VStack(alignment: .leading, spacing: VitalSpacing.xxs) {
                        HStack {
                            VitalStatusIndicator(status: a.isSeen ? .neutral : .info, text: a.kindDisplayName, compact: true)
                            Spacer()
                            if let d = a.createdAt { Text(d.formatted(.relative(presentation: .named))).vitalFont(.caption).foregroundStyle(VitalColors.textSecondary) }
                        }
                        Text(a.title).vitalFont(.cardTitle).foregroundStyle(VitalColors.textPrimary)
                        Text(a.summary).vitalFont(.secondary).foregroundStyle(VitalColors.textSecondary)
                        if let c = a.citation { CitationRow(citation: c) }
                    }
                    .padding(.vertical, VitalSpacing.xxs)
                    .task { await markSeen(a) }
                }
                .onDelete { idx in
                    let ids = idx.map { alerts[$0].id }
                    alerts.remove(atOffsets: idx)
                    Task { for id in ids { try? await model.research?.deleteAlert(id) } }
                }
            } header: { Text("Alerts") }
            .vitalRow()

            Section {
                ForEach(interests) { i in
                    NavigationLink { InsightCardView(compound: i.term, question: nil) } label: {
                        Label(i.title, systemImage: i.kind == .compound ? "pills" : "text.book.closed")
                    }
                }
                .onDelete { idx in
                    let ids = idx.map { interests[$0].id }
                    interests.remove(atOffsets: idx)
                    Task { for id in ids { _ = try? await model.research?.removeInterest(id) } }
                }
                HStack {
                    TextField("Follow a compound or topic", text: $newTerm)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onSubmit { Task { await add() } }
                    Button("Follow") { Task { await add() } }
                        .disabled(newTerm.nilIfBlank == nil)
                }
            } header: {
                Text("Following")
            } footer: {
                Text("Followed topics are checked about twice a day when you open the app. Only the topic name is searched.")
            }
            .vitalRow()

            if !saved.isEmpty {
                Section("Recent research cards") {
                    ForEach(saved) { s in
                        NavigationLink { InsightCardView(compound: s.compoundName, question: nil) } label: {
                            HStack {
                                Text(s.compoundName)
                                Spacer()
                                if let level = s.evidenceLevel { Text(level.shortName).vitalFont(.caption).foregroundStyle(level.tint) }
                            }
                        }
                    }
                    .onDelete { idx in
                        let ids = idx.map { saved[$0].id }
                        saved.remove(atOffsets: idx)
                        Task { for id in ids { try? await model.research?.deleteSavedCard(id) } }
                    }
                }
                .vitalRow()
            }
        }
        .vitalListBackground()
        .navigationTitle("Followed research")
        .refreshable { await model.checkResearchUpdates(); await load() }
        .task { await load() }
    }

    private func load() async {
        guard let research = model.research else { errorText = "Research needs an account with AI coaching turned on."; return }
        do {
            async let i = research.interests()
            async let a = research.alerts()
            async let s = research.savedCards()
            (interests, alerts, saved) = try await (i, a, s)
            errorText = nil
        } catch let e as CoachError {
            errorText = e.userMessage
        } catch {
            errorText = "Couldn't load followed research."
        }
    }

    private func add() async {
        guard let term = newTerm.nilIfBlank, let research = model.research else { return }
        do {
            let interest = try await research.addInterest(String(term.prefix(120)))
            if !interests.contains(where: { $0.id == interest.id }) { interests.append(interest) }
            newTerm = ""
        } catch let e as CoachError {
            errorText = e.userMessage
        } catch {
            errorText = "Couldn't follow this topic."
        }
    }

    private func markSeen(_ alert: ResearchAlert) async {
        guard !alert.isSeen, let research = model.research else { return }
        try? await research.markAlertSeen(alert.id)
        model.unseenResearchAlerts = max(0, model.unseenResearchAlerts - 1)
    }
}
