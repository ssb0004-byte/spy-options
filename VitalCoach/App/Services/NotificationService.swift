import Foundation
import UserNotifications
import VitalCore

/// Local reminders for scheduled doses and the daily check-in.
///
/// - Reminders are re-planned from scratch (idempotent ids = occurrence keys) whenever the
///   routine, the time zone, or logged doses change; iOS keeps at most 64 pending requests.
/// - "Taken" / "Skip" actions log an administration; nothing is ever assumed taken.
/// - With discreet reminders on (default), substance names never appear on the lock screen.
final class NotificationService: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let doseCategory = "DOSE_REMINDER"
    static let takenAction = "DOSE_TAKEN"
    static let skipAction = "DOSE_SKIP"
    static let dosePrefix = "dose:"
    static let checkInId = "checkin:daily"

    struct DoseResponse: Sendable {
        var occurrenceKey: String
        var regimenId: UUID
        var userSubstanceId: UUID
        var scheduledAt: Date
        var taken: Bool
    }

    private let center = UNUserNotificationCenter.current()
    /// Set by the app model; invoked when the user taps Taken/Skip on a reminder.
    var onDoseResponse: (@Sendable (DoseResponse) async -> Void)?

    override init() {
        super.init()
        center.delegate = self
        let taken = UNNotificationAction(identifier: Self.takenAction, title: "Taken", options: [])
        let skip = UNNotificationAction(identifier: Self.skipAction, title: "Skip", options: [])
        center.setNotificationCategories([UNNotificationCategory(identifier: Self.doseCategory, actions: [taken, skip], intentIdentifiers: [], options: [])])
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    @discardableResult
    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    func replaceDoseReminders(_ reminders: [ReminderRequest], plannedById: [String: PlannedDose]) async {
        let pending = await center.pendingNotificationRequests()
        center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix(Self.dosePrefix) })
        let cal = Calendar.current
        for r in reminders {
            guard let p = plannedById[r.id] else { continue }
            let content = UNMutableNotificationContent()
            content.title = r.title
            content.body = r.body
            content.sound = .default
            content.categoryIdentifier = Self.doseCategory
            content.userInfo = ["occurrenceKey": r.id, "regimenId": p.regimenId.uuidString,
                                "userSubstanceId": p.userSubstanceId.uuidString,
                                "scheduledAt": p.scheduledAt.timeIntervalSince1970]
            let comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: r.fireAt)
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            try? await center.add(UNNotificationRequest(identifier: Self.dosePrefix + r.id, content: content, trigger: trigger))
        }
    }

    func scheduleDailyCheckIn(enabled: Bool, at time: LocalTime) async {
        center.removePendingNotificationRequests(withIdentifiers: [Self.checkInId])
        guard enabled else { return }
        let content = UNMutableNotificationContent()
        content.title = "Daily check-in"
        content.body = "How are you feeling today? It takes under a minute."
        content.sound = .default
        let trigger = UNCalendarNotificationTrigger(dateMatching: DateComponents(hour: time.hour, minute: time.minute), repeats: true)
        try? await center.add(UNNotificationRequest(identifier: Self.checkInId, content: content, trigger: trigger))
    }

    static let briefingId = "coach:morning-briefing"

    /// Daily nudge to open the AI morning briefing (generated on demand when the app opens).
    func scheduleMorningBriefing(enabled: Bool, at time: LocalTime) async {
        center.removePendingNotificationRequests(withIdentifiers: [Self.briefingId])
        guard enabled else { return }
        let content = UNMutableNotificationContent()
        content.title = "Your morning briefing"
        content.body = "A quick look at your trends and today's focus."
        content.sound = .default
        let trigger = UNCalendarNotificationTrigger(dateMatching: DateComponents(hour: time.hour, minute: time.minute), repeats: true)
        try? await center.add(UNNotificationRequest(identifier: Self.briefingId, content: content, trigger: trigger))
    }

    func removeAll() {
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
    }

    // MARK: UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard response.actionIdentifier == Self.takenAction || response.actionIdentifier == Self.skipAction,
              let key = info["occurrenceKey"] as? String,
              let regimen = (info["regimenId"] as? String).flatMap(UUID.init(uuidString:)),
              let substance = (info["userSubstanceId"] as? String).flatMap(UUID.init(uuidString:)),
              let at = info["scheduledAt"] as? TimeInterval else { return }
        await onDoseResponse?(DoseResponse(occurrenceKey: key, regimenId: regimen, userSubstanceId: substance,
                                           scheduledAt: Date(timeIntervalSince1970: at),
                                           taken: response.actionIdentifier == Self.takenAction))
    }
}
