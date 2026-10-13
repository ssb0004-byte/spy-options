import Foundation
import VitalCore

/// Why the coach can or can't be used right now, with the fix the UI offers.
enum CoachAvailability: Equatable {
    case deviceOnly          // signed in without an account
    case needsCloudBackup    // the coach reads synced records on the server
    case needsAIConsent
    case ready
}

extension AppModel {
    var briefingReminderTime: LocalTime {
        let minutes = UserDefaults.standard.object(forKey: "coach.briefingMinutes") as? Int ?? (7 * 60 + 30)
        return LocalTime(hour: minutes / 60, minute: minutes % 60)
    }

    func setBriefingReminderTime(_ t: LocalTime) {
        UserDefaults.standard.set(t.hour * 60 + t.minute, forKey: "coach.briefingMinutes")
    }

    var coachAvailability: CoachAvailability {
        guard coach != nil else { return .deviceOnly }
        if !data.consents.isGranted(.cloudSync) { return .needsCloudBackup }
        if !data.consents.isGranted(.aiProcessing) { return .needsAIConsent }
        return .ready
    }

    /// Loads today's briefing (generated at most once per day on the server, then cached).
    func loadBriefing(force: Bool = false) async {
        guard coachAvailability == .ready, let coach, !isLoadingBriefing else { return }
        if !force, let b = briefing, b.forDate == CoachDates.localDate(Date(), timeZone: .current) { return }
        isLoadingBriefing = true
        defer { isLoadingBriefing = false }
        // Make sure the server has today's data before it summarises it.
        await syncNow()
        do {
            let r = try await coach.send(.morningBriefing, forceRefresh: force)
            briefing = r.insight
            briefingMessage = nil
        } catch let e as CoachError {
            briefingMessage = e.userMessage
        } catch {
            briefingMessage = "Couldn't load your briefing."
        }
    }

    /// Applies a coach goal proposal — only ever called from an explicit user tap.
    func acceptGoalProposal(_ insight: CoachInsight) async {
        guard let payload = insight.payload else { return }
        let newGoals = GoalProposalApplier.apply(payload, to: Set(data.activeGoals))
        await setGoals(newGoals)
        try? await coach?.setInsightStatus(insight.id, "accepted")
    }

    func dismissInsight(_ insight: CoachInsight) async {
        try? await coach?.setInsightStatus(insight.id, "dismissed")
    }
}
