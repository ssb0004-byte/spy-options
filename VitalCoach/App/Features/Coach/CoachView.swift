import SwiftUI
import VitalCore

struct CoachView: View {
    @Environment(AppModel.self) var model

    var body: some View {
        NavigationStack {
            Group {
                switch model.coachAvailability {
                case .ready: CoachHomeView()
                default: CoachGateView()
                }
            }
            .navigationTitle("Coach")
        }
    }
}

/// Explains what's needed before the coach can run, with the one-tap fix.
struct CoachGateView: View {
    @Environment(AppModel.self) var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                switch model.coachAvailability {
                case .deviceOnly:
                    EmptyStateView(title: "Sign in to use the coach",
                                   message: "The AI coach runs on VitalCoach's secure server, so it needs an account. Go to Profile → Leave device-only mode, then Sign in with Apple.",
                                   systemImage: "person.badge.key")
                case .needsCloudBackup:
                    EmptyStateView(title: "Turn on backup first",
                                   message: "The coach reads your synced records on the server (only yours, protected by your account). Turn on cloud backup to continue.",
                                   systemImage: "icloud.and.arrow.up", actionTitle: "Turn on backup") {
                        Task { await model.setConsent(.cloudSync, granted: true) }
                    }
                case .needsAIConsent, .ready:
                    Card(title: "Allow AI coaching", systemImage: "sparkles") {
                        Text(ConsentType.aiProcessing.explanation).font(.callout)
                        Text("Only a short summary of the relevant parts of your records is sent per request: recent trends, your routine, check-in averages and memories you've approved. Never your full history. You can see exactly what's shared before agreeing.")
                            .font(.footnote).foregroundStyle(.secondary)
                        NavigationLink("See what the coach would see") { ContextPreviewView() }
                            .font(.callout)
                        Button("Allow AI coaching") { Task { await model.setConsent(.aiProcessing, granted: true) } }
                            .buttonStyle(.borderedProminent)
                    }
                }
                Card(title: "How the coach handles your data", systemImage: "lock.shield") {
                    Text("• Separate opt-in consent; you can withdraw it any time in Profile → Consents.\n• Your data isn't used to train AI models, and replies aren't stored by the AI provider for reuse.\n• The coach never prescribes or changes doses, and flags anything that needs a clinician.\n• You control what it remembers.")
                        .font(.callout)
                }
            }
            .padding(Theme.Spacing.l)
        }
        .background(Theme.pageBackground)
    }
}

struct CoachHomeView: View {
    @Environment(AppModel.self) var model
    @State var conversations: [CoachConversation] = []
    @State var insights: [CoachInsight] = []
    @State var loadError: String?
    @State var running: CoachMode?
    @State var openedInsight: CoachInsight?
    @State var startChat = false

    private var proposals: [CoachInsight] { insights.filter { $0.kind == "goal_proposal" && $0.status == "new" } }
    private var reviews: [CoachInsight] { insights.filter { $0.kind == "weekly_summary" || $0.kind == "goal_reassessment" } }

    var body: some View {
        List {
            if let loadError { Section { NoticeBanner(style: .warning, text: loadError) } }

            Section {
                Button { startChat = true } label: { Label("New conversation", systemImage: "square.and.pencil") }
                actionButton("Weekly review", systemImage: "calendar", mode: .weeklySummary)
                actionButton("Reassess my goals", systemImage: "target", mode: .goalReassessment)
                actionButton("Talk about today's check-in", systemImage: "checkmark.bubble", mode: .checkinFollowup)
            } header: {
                Text("Your coach · \(model.data.preferences?.coachPersonality.displayName ?? CoachPersonality.balanced.displayName)")
            }

            if !proposals.isEmpty {
                Section("Suggestions waiting for you") {
                    ForEach(proposals) { p in GoalProposalRow(insight: p) { await refresh() } }
                }
            }

            if !reviews.isEmpty {
                Section("Reviews") {
                    ForEach(reviews.prefix(8)) { i in
                        Button { openedInsight = i } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(i.title).foregroundStyle(.primary)
                                Text("\(i.kind == "weekly_summary" ? "Week of" : "On") \(i.forDate)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            Section("Conversations") {
                if conversations.isEmpty {
                    Text("No conversations yet. Ask anything about your goals, trends or routine.").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(conversations) { c in
                    NavigationLink { ChatView(conversationId: c.id, title: c.title) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.title).lineLimit(1)
                            if let d = c.updatedAt { Text(d.formatted(.relative(presentation: .named))).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
                .onDelete { idx in
                    let ids = idx.map { conversations[$0].id }
                    conversations.remove(atOffsets: idx)
                    Task { for id in ids { try? await model.coach?.deleteConversation(id) } }
                }
            }

            Section("Privacy & memory") {
                NavigationLink { MemoryView() } label: { Label("What the coach remembers", systemImage: "brain") }
                NavigationLink { ContextPreviewView() } label: { Label("What the coach can see", systemImage: "eye") }
            }

            Section {
                Text("Educational coaching, not medical advice. The coach never prescribes or changes doses. In an emergency, call your local emergency number.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationDestination(isPresented: $startChat) { ChatView(conversationId: nil, title: "New conversation") }
        .navigationDestination(item: $openedConversation) { c in ChatView(conversationId: c.id, title: c.title) }
        .sheet(item: $openedInsight) { i in InsightSheet(insight: i) }
        .refreshable { await refresh() }
        .task { await refresh() }
    }

    private func actionButton(_ title: String, systemImage: String, mode: CoachMode) -> some View {
        Button {
            Task { await run(mode) }
        } label: {
            HStack {
                Label(title, systemImage: systemImage)
                Spacer()
                if running == mode { ProgressView() }
            }
        }
        .disabled(running != nil)
    }

    private func run(_ mode: CoachMode) async {
        guard let coach = model.coach else { return }
        running = mode
        defer { running = nil }
        await model.syncNow()
        do {
            if mode == .checkinFollowup {
                let r = try await coach.send(.checkinFollowup, message: "I just finished today's check-in.")
                await refresh()
                openedConversation = conversations.first { $0.id == r.conversationId }
                    ?? r.conversationId.map { CoachConversation(id: $0, title: "Check-in follow-up", kind: "checkin_followup", updatedAt: Date()) }
                return
            }
            let r = try await coach.send(mode, forceRefresh: mode == .weeklySummary)
            await refresh()
            openedInsight = r.insight
        } catch let e as CoachError {
            loadError = e.userMessage
        } catch {
            loadError = "Something went wrong. Please try again."
        }
    }

    @State var openedConversation: CoachConversation?

    private func refresh() async {
        guard let coach = model.coach else { return }
        do {
            async let c = coach.conversations()
            async let i = coach.insights()
            conversations = try await c
            insights = try await i
            loadError = nil
        } catch let e as CoachError {
            loadError = e.userMessage
        } catch {
            loadError = "Couldn't load the coach."
        }
    }
}

struct GoalProposalRow: View {
    @Environment(AppModel.self) var model
    var insight: CoachInsight
    var onChange: () async -> Void
    @State var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Text(insight.title).font(.subheadline.weight(.semibold))
            if let add = insight.payload?.goalsToAdd, !add.isEmpty {
                Text("Add: " + add.map(\.displayName).joined(separator: ", ")).font(.callout)
            }
            if let remove = insight.payload?.goalsToRemove, !remove.isEmpty {
                Text("Remove: " + remove.map(\.displayName).joined(separator: ", ")).font(.callout)
            }
            Text(insight.body).font(.footnote).foregroundStyle(.secondary)
            HStack {
                Button("Accept") {
                    working = true
                    Task { await model.acceptGoalProposal(insight); await onChange(); working = false }
                }
                .buttonStyle(.borderedProminent)
                Button("Not now") {
                    working = true
                    Task { await model.dismissInsight(insight); await onChange(); working = false }
                }
                .buttonStyle(.bordered)
            }
            .disabled(working)
        }
        .padding(.vertical, 4)
    }
}

struct InsightSheet: View {
    @Environment(\.dismiss) var dismiss
    var insight: CoachInsight

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                    Text(insight.body).font(.body).textSelection(.enabled)
                    BasisFooter(basis: insight.payload?.basis, dataPoints: insight.payload?.dataPointsUsed)
                }
                .padding()
            }
            .navigationTitle(insight.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

/// Shows whether a reply was based on the user's data or general education, and which data.
struct BasisFooter: View {
    var basis: String?
    var dataPoints: [String]?

    var body: some View {
        let meta: CoachMetadata = {
            var m = CoachMetadata()
            m.basis = basis
            return m
        }()
        VStack(alignment: .leading, spacing: 4) {
            if let label = meta.basisLabel {
                Label(label, systemImage: basis == "general_education" ? "book" : "chart.xyaxis.line")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let points = dataPoints, !points.isEmpty {
                Text("Used: " + points.joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Chat

struct ChatView: View {
    @Environment(AppModel.self) var model
    @State var conversationId: UUID?
    var title: String

    @State var messages: [CoachMessage] = []
    @State var draft = ""
    @State var sending = false
    @State var errorText: String?
    @State var memoryNote: String?

    init(conversationId: UUID?, title: String) {
        _conversationId = State(initialValue: conversationId)
        self.title = title
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Theme.Spacing.m) {
                        if messages.isEmpty && !sending {
                            Text("Ask about your trends, your routine, a supplement you're curious about, or how to work toward a goal. The coach uses your synced data and will say when it doesn't know.")
                                .font(.callout).foregroundStyle(.secondary).padding(.top)
                        }
                        ForEach(messages) { m in MessageBubble(message: m).id(m.id) }
                        if sending {
                            HStack { ProgressView(); Text("Thinking…").font(.callout).foregroundStyle(.secondary) }.id("typing")
                        }
                        if let memoryNote { NoticeBanner(style: .info, text: memoryNote) }
                        if let errorText { NoticeBanner(style: .warning, text: errorText) }
                    }
                    .padding()
                }
                .onChange(of: messages.count) { _, _ in
                    if let last = messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
            Divider()
            HStack(alignment: .bottom) {
                TextField("Message your coach", text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.roundedBorder)
                    .disabled(sending)
                Button {
                    let text = draft
                    draft = ""
                    Task { await send(text) }
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.title)
                }
                .disabled(sending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("Send")
            }
            .padding()
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        guard let id = conversationId, let coach = model.coach else { return }
        do { messages = try await coach.messages(conversationId: id) } catch { errorText = (error as? CoachError)?.userMessage ?? "Couldn't load messages." }
    }

    private func send(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let coach = model.coach else { return }
        errorText = nil; memoryNote = nil
        let pending = CoachMessage(id: UUID(), conversationId: conversationId ?? UUID(), role: "user", content: trimmed, createdAt: Date())
        messages.append(pending)
        sending = true
        defer { sending = false }
        await model.syncNow()
        do {
            let r = try await coach.send(.chat, message: trimmed, conversationId: conversationId)
            if let id = r.conversationId { conversationId = id }
            if let reply = r.message { messages.append(reply) }
            if let n = r.proposedMemories, n > 0 {
                memoryNote = "The coach suggested \(n == 1 ? "something" : "\(n) things") to remember. Review in Coach → What the coach remembers."
            }
        } catch let e as CoachError {
            errorText = e.userMessage
            messages.removeAll { $0.id == pending.id }
            draft = trimmed
        } catch {
            errorText = "Something went wrong. Please try again."
            messages.removeAll { $0.id == pending.id }
            draft = trimmed
        }
    }
}

struct MessageBubble: View {
    var message: CoachMessage

    var body: some View {
        switch message.role {
        case "user":
            HStack {
                Spacer(minLength: 40)
                Text(message.content)
                    .padding(Theme.Spacing.m)
                    .background(Theme.accent.opacity(0.18), in: RoundedRectangle(cornerRadius: 16))
                    .textSelection(.enabled)
            }
            .accessibilityLabel("You: \(message.content)")
        case "system_notice":
            NoticeBanner(style: .critical, text: message.content)
        default:
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                Text(message.content).textSelection(.enabled)
                if let q = message.metadata?.followUpQuestion {
                    Text(q).font(.callout.italic()).foregroundStyle(.secondary)
                }
                BasisFooter(basis: message.metadata?.basis, dataPoints: message.metadata?.dataPointsUsed)
            }
            .padding(Theme.Spacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 16))
            .accessibilityElement(children: .combine)
        }
    }
}

// MARK: - Memory

struct MemoryView: View {
    @Environment(AppModel.self) var model
    @State var memories: [CoachMemory] = []
    @State var errorText: String?
    @State var editing: CoachMemory?
    @State var adding = false
    @State var confirmClear = false

    var body: some View {
        List {
            if let errorText { Section { NoticeBanner(style: .warning, text: errorText) } }
            let proposed = memories.filter { $0.status == .proposed }
            if !proposed.isEmpty {
                Section {
                    ForEach(proposed) { m in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(m.content)
                            Text(m.category.displayName).font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Button("Remember") { Task { await update(m, status: .active) } }.buttonStyle(.borderedProminent)
                                Button("Discard") { Task { await delete(m) } }.buttonStyle(.bordered)
                            }
                        }
                    }
                } header: {
                    Text("Suggested by the coach")
                } footer: {
                    Text("Nothing is remembered until you approve it.")
                }
            }
            Section {
                let active = memories.filter { $0.status == .active }
                if active.isEmpty { Text("Nothing yet.").foregroundStyle(.secondary) }
                ForEach(active) { m in
                    Button { editing = m } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(m.content).foregroundStyle(.primary)
                            Text("\(m.category.displayName) · \(m.source == "coach" ? "suggested by coach" : "added by you")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions { Button("Delete", role: .destructive) { Task { await delete(m) } } }
                }
                Button { adding = true } label: { Label("Add something to remember", systemImage: "plus") }
            } header: {
                Text("Remembered")
            } footer: {
                Text("These notes are included when the coach responds. Your health records themselves are never stored as memory.")
            }
            Section {
                Button("Clear all memory", role: .destructive) { confirmClear = true }
            }
        }
        .navigationTitle("Coach memory")
        .task { await load() }
        .refreshable { await load() }
        .sheet(item: $editing) { m in MemoryEditor(memory: m) { text in Task { await update(m, content: text) } } }
        .sheet(isPresented: $adding) { MemoryEditor(memory: nil) { text, category in Task { await add(text, category) } } }
        .confirmationDialog("Clear everything the coach remembers?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear all", role: .destructive) { Task { try? await model.coach?.clearMemory(); await load() } }
        }
    }

    private func load() async {
        guard let coach = model.coach else { return }
        do { memories = try await coach.memories(); errorText = nil } catch { errorText = (error as? CoachError)?.userMessage ?? "Couldn't load memory." }
    }
    private func update(_ m: CoachMemory, content: String? = nil, status: CoachMemory.Status? = nil) async {
        do { try await model.coach?.updateMemory(m.id, content: content, status: status) } catch { errorText = "Couldn't save the change." }
        await load()
    }
    private func delete(_ m: CoachMemory) async {
        do { try await model.coach?.deleteMemory(m.id) } catch { errorText = "Couldn't delete." }
        await load()
    }
    private func add(_ text: String, _ category: CoachMemory.Category) async {
        guard let userId = model.userId else { return }
        do { try await model.coach?.addMemory(userId: userId, category: category, content: text) } catch { errorText = "Couldn't save." }
        await load()
    }
}

struct MemoryEditor: View {
    @Environment(\.dismiss) var dismiss
    var memory: CoachMemory?
    var onSaveEdit: ((String) -> Void)?
    var onSaveNew: ((String, CoachMemory.Category) -> Void)?
    @State var text = ""
    @State var category: CoachMemory.Category = .preference

    init(memory: CoachMemory?, onSave: @escaping (String) -> Void) {
        self.memory = memory; self.onSaveEdit = onSave; self.onSaveNew = nil
    }
    init(memory: CoachMemory?, onSave: @escaping (String, CoachMemory.Category) -> Void) {
        self.memory = memory; self.onSaveNew = onSave; self.onSaveEdit = nil
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("e.g. I prefer short, direct answers", text: $text, axis: .vertical).lineLimit(2...6)
                if memory == nil {
                    Picker("Type", selection: $category) {
                        ForEach(CoachMemory.Category.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                }
            }
            .navigationTitle(memory == nil ? "New memory" : "Edit memory")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if let onSaveEdit { onSaveEdit(t) } else { onSaveNew?(t, category) }
                        dismiss()
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { text = memory?.content ?? "" }
        }
    }
}

// MARK: - Transparency

struct ContextPreviewView: View {
    @Environment(AppModel.self) var model
    @State var text: String?
    @State var errorText: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                Text("This is the exact summary sent to the AI with each request, built from your synced records. Nothing else from your history is included.")
                    .font(.callout).foregroundStyle(.secondary)
                if let errorText { NoticeBanner(style: .warning, text: errorText) }
                if let text {
                    Text(text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .padding().frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 12))
                } else if errorText == nil {
                    ProgressView()
                }
            }
            .padding()
        }
        .navigationTitle("What the coach can see")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard let coach = model.coach else { errorText = "Sign in to use the coach."; return }
            await model.syncNow()
            do { text = try await coach.contextPreview() } catch { errorText = (error as? CoachError)?.userMessage ?? "Couldn't load." }
        }
    }
}
