import SwiftUI
import VitalCore

/// Phase 1 placeholder. The AI coach (Phase 2) requires the secure server-side OpenAI
/// integration and separate AI-processing consent; nothing here simulates AI output.
struct CoachView: View {
    @Environment(AppModel.self) var model

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                    EmptyStateView(title: "Coach is coming next",
                                   message: "Your AI coach will chat with you, write morning briefings and weekly summaries, and explain research, using only the data you allow.",
                                   systemImage: "bubble.left.and.text.bubble.right")
                    Card(title: "Your coaching style", systemImage: "person.wave.2") {
                        Text(model.data.preferences?.coachPersonality.displayName ?? CoachPersonality.balanced.displayName)
                        Text("Change it anytime in Profile. Your history is kept when you switch.").font(.caption).foregroundStyle(.secondary)
                    }
                    Card(title: "How the coach will handle your data", systemImage: "lock.shield") {
                        Text("• Separate opt-in consent before any health information is sent for AI processing.\n• Only the minimum relevant records per request, never your full history.\n• Not used to train AI models.\n• You'll be able to view, correct and clear what the coach remembers.")
                            .font(.callout)
                    }
                }
                .padding(Theme.Spacing.l)
            }
            .background(Theme.pageBackground)
            .navigationTitle("Coach")
        }
    }
}
