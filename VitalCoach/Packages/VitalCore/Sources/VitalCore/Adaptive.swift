import Foundation

// MARK: - Check-in planning

public enum CheckInQuestion: String, Sendable, CaseIterable, Codable {
    case wellbeing, energy, pain, stiffness, mobility, cognition, sideEffects = "side_effects", notes
}

/// Decides which check-in questions to ask today. Deterministic and explainable:
/// every question has a reason shown in the UI ("Asked because …").
public enum CheckInPlanner {
    /// Bump when question wording/scales change so trends compare like with like.
    public static let questionSetVersion = 1

    public struct Context: Sendable {
        public var goals: Set<HealthGoal>
        public var today: LocalDate
        public var todayWeekday: Int
        public var weeklyCheckInWeekday: Int
        public var recentPain: [PainEntry]          // last 7 days
        public var recentEntries: [SymptomEntry]    // last 7 days
        public var substancesStartedOrChangedWithin14Days: Int
        public var openAdverseEffects: Int
        public init(goals: Set<HealthGoal>, today: LocalDate, todayWeekday: Int, weeklyCheckInWeekday: Int,
                    recentPain: [PainEntry], recentEntries: [SymptomEntry],
                    substancesStartedOrChangedWithin14Days: Int, openAdverseEffects: Int) {
            self.goals = goals; self.today = today; self.todayWeekday = todayWeekday
            self.weeklyCheckInWeekday = weeklyCheckInWeekday; self.recentPain = recentPain
            self.recentEntries = recentEntries
            self.substancesStartedOrChangedWithin14Days = substancesStartedOrChangedWithin14Days
            self.openAdverseEffects = openAdverseEffects
        }
    }

    public struct Plan: Sendable, Equatable {
        public var isWeekly: Bool
        public var questions: [CheckInQuestion]
        public var reasons: [CheckInQuestion: String]
    }

    public static func plan(_ c: Context) -> Plan {
        let weekly = c.todayWeekday == c.weeklyCheckInWeekday
        if weekly {
            return Plan(isWeekly: true, questions: CheckInQuestion.allCases,
                        reasons: Dictionary(uniqueKeysWithValues: CheckInQuestion.allCases.map { ($0, "Weekly full check-in") }))
        }
        var q: [CheckInQuestion] = [.wellbeing]
        var reasons: [CheckInQuestion: String] = [.wellbeing: "Daily baseline"]

        if c.goals.contains(.energy) || c.goals.contains(.recovery) {
            q.append(.energy); reasons[.energy] = "You're tracking energy or recovery"
        }
        let recentPainful = c.recentPain.contains { $0.severity > 0 }
        if c.goals.contains(.reducedPain) || recentPainful {
            q.append(.pain)
            reasons[.pain] = c.goals.contains(.reducedPain) ? "You're working on reducing pain" : "You reported pain this week"
        }
        if c.goals.contains(.mobility) || recentPainful {
            q.append(.stiffness); reasons[.stiffness] = "Tracks mobility and stiffness over time"
        }
        if c.goals.contains(.cognitivePerformance) {
            q.append(.cognition); reasons[.cognition] = "You're tracking cognitive performance"
        }
        if c.substancesStartedOrChangedWithin14Days > 0 || c.openAdverseEffects > 0 {
            q.append(.sideEffects)
            reasons[.sideEffects] = c.openAdverseEffects > 0 ? "Following up on a reported side effect" : "You recently started or changed something"
        }
        q.append(.notes); reasons[.notes] = "Optional"
        return Plan(isWeekly: false, questions: q, reasons: reasons)
    }
}

// MARK: - Onboarding

public enum OnboardingStep: String, Sendable, CaseIterable, Codable {
    case welcome
    case consent          // required: terms + 18+
    case name             // optional
    case goals            // required: at least one
    case units
    case basics           // DOB, height, sex — optional
    case healthKit        // optional
    case cloudSync        // optional consent
    case coachStyle
    case done

    public var isRequired: Bool { self == .consent || self == .goals || self == .welcome || self == .done }
}

/// Adaptive, progressive onboarding: only a few required steps up front; the rest is
/// skippable and resurfaced later as gentle "complete your profile" prompts.
public struct OnboardingState: Sendable, Equatable, Codable {
    public var completed: Set<OnboardingStep> = []
    public var skipped: Set<OnboardingStep> = []
    public init() {}

    public mutating func complete(_ s: OnboardingStep) { completed.insert(s); skipped.remove(s) }
    public mutating func skip(_ s: OnboardingStep) {
        guard !s.isRequired else { return }
        skipped.insert(s)
    }

    public func nextStep(consents: ConsentState, hasGoals: Bool, healthKitAvailable: Bool) -> OnboardingStep {
        for step in OnboardingStep.allCases {
            if completed.contains(step) || skipped.contains(step) { continue }
            switch step {
            case .consent where consents.isGranted(.termsAndAge): continue
            case .goals where hasGoals: continue
            case .healthKit where !healthKitAvailable: continue
            case .cloudSync where consents.isGranted(.cloudSync): continue
            default: return step
            }
        }
        return .done
    }

    /// Items to suggest later on the profile screen (skipped optional steps).
    public var deferredPrompts: [OnboardingStep] {
        OnboardingStep.allCases.filter { skipped.contains($0) }
    }
}

public enum AgeGate {
    /// Adults only. Returns false when the date of birth makes the user under 18.
    public static func isAdult(dateOfBirth: LocalDate, now: Date, calendar: Calendar) -> Bool {
        guard let dob = dateOfBirth.startOfDay(in: calendar),
              let years = calendar.dateComponents([.year], from: dob, to: now).year else { return false }
        return years >= 18
    }
}

// MARK: - Urgent symptom screening

/// Conservative, deterministic screen for check-in input that may need emergency care.
/// This is not diagnosis: it errs toward showing an "if this is an emergency…" message.
/// Phase 3 replaces the phrase list with a clinically reviewed rule set.
public enum UrgentSymptomScreen {
    public struct Result: Sendable, Equatable {
        public var isUrgent: Bool
        public var matched: [String]
    }

    static let phrases: [String] = [
        "chest pain", "chest pressure", "chest tightness", "can't breathe", "cannot breathe", "trouble breathing",
        "shortness of breath", "difficulty breathing", "face drooping", "slurred speech", "sudden weakness",
        "sudden numbness", "worst headache", "fainted", "passed out", "loss of consciousness", "seizure",
        "suicidal", "suicide", "kill myself", "end my life", "overdose", "throat swelling", "tongue swelling",
        "anaphylaxis", "coughing blood", "vomiting blood", "black stool", "severe bleeding",
    ]

    public static func screen(text: String?, pain: [PainEntry] = []) -> Result {
        let lower = (text ?? "").lowercased()
        var matched = phrases.filter { lower.contains($0) }
        if pain.contains(where: { $0.location == .chest && $0.severity >= 7 }) { matched.append("severe chest pain") }
        return Result(isUrgent: !matched.isEmpty, matched: matched)
    }

    public static let message = "Your entry mentions symptoms that can be serious. If this is happening now or feels like an emergency, call your local emergency number (911 in the US) or go to the nearest emergency department. If you are thinking about harming yourself, call or text 988 (US) or your local crisis line. VitalCoach cannot assess emergencies."
}

// MARK: - Reminder planning

public struct ReminderRequest: Sendable, Equatable, Identifiable {
    public var id: String          // = occurrenceKey, so re-planning is idempotent
    public var fireAt: Date
    public var title: String
    public var body: String
    public var userSubstanceId: UUID
}

public enum ReminderPlanner {
    /// iOS allows 64 pending local notifications per app; keep headroom for check-in reminders.
    public static let maxPending = 56

    /// Upcoming planned doses that still need a reminder, soonest first, capped.
    /// `names` maps substance id → name; when `discreet` the name is hidden on the lock screen.
    public static func plan(planned: [PlannedDose], records: [ActualAdministration], names: [UUID: String],
                            remindersEnabled: Set<UUID>, discreet: Bool, now: Date) -> [ReminderRequest] {
        let effective = DoseLog.effectiveRecords(records)
        let logged = Set(effective.compactMap(\.occurrenceKey))
        return planned
            .filter { $0.scheduledAt > now && !logged.contains($0.occurrenceKey) && remindersEnabled.contains($0.regimenId) }
            .sorted { $0.scheduledAt < $1.scheduledAt }
            .prefix(maxPending)
            .map { p in
                let name = names[p.userSubstanceId] ?? "your routine"
                return ReminderRequest(
                    id: p.occurrenceKey, fireAt: p.scheduledAt,
                    title: discreet ? "Scheduled routine item" : name,
                    body: discreet ? "Tap to confirm or skip." : "\(p.dose.formatted), \(p.route.displayName.lowercased()). Tap to confirm or skip.",
                    userSubstanceId: p.userSubstanceId)
            }
    }
}
