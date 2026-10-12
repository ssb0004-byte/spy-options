import Foundation

public enum HealthGoal: String, Codable, Sendable, CaseIterable, Identifiable {
    case strength
    case muscleMass = "muscle_mass"
    case mobility
    case reducedPain = "reduced_pain"
    case cognitivePerformance = "cognitive_performance"
    case energy
    case longevity
    case fatLoss = "fat_loss"
    case recovery

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .strength: "Increase strength"
        case .muscleMass: "Build muscle"
        case .mobility: "Mobility & flexibility"
        case .reducedPain: "Reduce pain"
        case .cognitivePerformance: "Cognitive performance"
        case .energy: "More energy, less fatigue"
        case .longevity: "Longevity & healthy aging"
        case .fatLoss: "Fat loss"
        case .recovery: "Recovery & injury prevention"
        }
    }

    public var symbolName: String {
        switch self {
        case .strength: "dumbbell"
        case .muscleMass: "figure.strengthtraining.traditional"
        case .mobility: "figure.flexibility"
        case .reducedPain: "bandage"
        case .cognitivePerformance: "brain.head.profile"
        case .energy: "bolt.heart"
        case .longevity: "leaf"
        case .fatLoss: "scalemass"
        case .recovery: "bed.double"
        }
    }

    /// Measurable indicators the app can track for this goal (deterministic suggestion,
    /// not AI-generated). Self-reported indicators come from check-ins.
    public var suggestedIndicators: [String] {
        switch self {
        case .strength: ["Self-reported strength notes", "Lean body mass trend (estimate)"]
        case .muscleMass: ["Lean body mass trend (estimate)", "Arm & thigh circumference", "Body weight"]
        case .mobility: ["Stiffness score (0–10)", "Mobility limitations in check-ins"]
        case .reducedPain: ["Pain severity (0–10) by location", "Functional impact of pain"]
        case .cognitivePerformance: ["Self-rated mental clarity (1–5)"]
        case .energy: ["Self-rated energy (1–5)", "Resting heart rate", "HRV trend"]
        case .longevity: ["Resting heart rate", "HRV trend", "Daily steps", "Waist circumference"]
        case .fatLoss: ["Body weight 7-day average", "Waist circumference", "Body fat % (estimate)"]
        case .recovery: ["HRV trend", "Resting heart rate", "Pain & stiffness"]
        }
    }
}

public struct UserGoal: SyncableRecord {
    public static let entity = EntityName.userGoals
    public var id: UUID
    public var userId: UUID
    public var goal: HealthGoal
    /// Optional ranking; nil = unranked (ranking is never required).
    public var priority: Int?
    public var note: String?
    public var isActive: Bool
    public var createdAt: Date
    public var clientUpdatedAt: Date
    public var version: Int
    public var deletedAt: Date?

    public init(id: UUID = UUID(), userId: UUID, goal: HealthGoal, priority: Int? = nil, note: String? = nil,
                isActive: Bool = true, createdAt: Date = Date(), clientUpdatedAt: Date = Date(), version: Int = 0, deletedAt: Date? = nil) {
        self.id = id; self.userId = userId; self.goal = goal; self.priority = priority; self.note = note
        self.isActive = isActive; self.createdAt = createdAt; self.clientUpdatedAt = clientUpdatedAt
        self.version = version; self.deletedAt = deletedAt
    }
    public var sortDate: Date { createdAt }
    public var indexTag: String? { goal.rawValue }
}

public enum ActivityLevel: String, Codable, Sendable, CaseIterable {
    case sedentary, light, moderate, active, veryActive = "very_active"
    public var displayName: String {
        switch self {
        case .sedentary: "Mostly sitting"
        case .light: "Lightly active"
        case .moderate: "Moderately active"
        case .active: "Active"
        case .veryActive: "Very active"
        }
    }
}

/// Physiological sex is optional and only used where reference ranges differ.
public enum PhysiologicalSex: String, Codable, Sendable, CaseIterable {
    case female, male, intersex
    case preferNotToSay = "prefer_not_to_say"
    public var displayName: String {
        switch self {
        case .female: "Female"
        case .male: "Male"
        case .intersex: "Intersex"
        case .preferNotToSay: "Prefer not to say"
        }
    }
}

public enum CoachPersonality: String, Codable, Sendable, CaseIterable {
    case encouragingTrainer = "encouraging_trainer"
    case clinicalAnalytical = "clinical_analytical"
    case friendlyConversational = "friendly_conversational"
    case directAccountability = "direct_accountability"
    case balanced
    public var displayName: String {
        switch self {
        case .encouragingTrainer: "Encouraging trainer"
        case .clinicalAnalytical: "Clinical & analytical"
        case .friendlyConversational: "Friendly & conversational"
        case .directAccountability: "Direct & accountability-focused"
        case .balanced: "Balanced trainer + science educator"
        }
    }
}

/// One row per user; `id == userId`.
public struct UserProfile: SyncableRecord {
    public static let entity = EntityName.userProfiles
    public var id: UUID
    public var userId: UUID
    public var displayName: String?
    public var dateOfBirth: LocalDate?
    public var physiologicalSex: PhysiologicalSex?
    /// Optional context the user chooses to share (e.g. on hormone therapy). Free text.
    public var sexContextNote: String?
    public var heightCm: Double?
    public var activityLevel: ActivityLevel?
    public var medicalConditions: [String]
    public var allergies: [String]
    public var injuries: [String]
    public var baselinePain: Int?
    public var baselineEnergy: Int?
    public var baselineMobility: Int?
    public var baselineCognition: Int?
    public var onboardingCompletedAt: Date?
    public var clientUpdatedAt: Date
    public var version: Int
    public var deletedAt: Date?

    public init(userId: UUID, displayName: String? = nil, clientUpdatedAt: Date = Date()) {
        self.id = userId; self.userId = userId; self.displayName = displayName
        self.medicalConditions = []; self.allergies = []; self.injuries = []
        self.clientUpdatedAt = clientUpdatedAt; self.version = 0
    }
    public var sortDate: Date { clientUpdatedAt }

    public func age(on date: Date, calendar: Calendar) -> Int? {
        guard let dob = dateOfBirth?.startOfDay(in: calendar) else { return nil }
        return calendar.dateComponents([.year], from: dob, to: date).year
    }
}

public struct NotificationSettings: Codable, Sendable, Equatable {
    public var doseReminders: Bool = true
    public var dailyCheckIn: Bool = true
    public var checkInTime: LocalTime = LocalTime(hour: 20, minute: 0)
    /// Hide substance names on the lock screen.
    public var discreetReminders: Bool = true
    public init() {}
}

public struct UserPreferences: SyncableRecord {
    public static let entity = EntityName.userPreferences
    public var id: UUID
    public var userId: UUID
    public var unitSystem: UnitSystem
    public var coachPersonality: CoachPersonality
    public var notifications: NotificationSettings
    /// Day of week (1 = Sunday) for the weekly full check-in.
    public var weeklyCheckInWeekday: Int
    public var clientUpdatedAt: Date
    public var version: Int
    public var deletedAt: Date?

    public init(userId: UUID, unitSystem: UnitSystem = .metric, coachPersonality: CoachPersonality = .balanced,
                clientUpdatedAt: Date = Date()) {
        self.id = userId; self.userId = userId; self.unitSystem = unitSystem; self.coachPersonality = coachPersonality
        self.notifications = NotificationSettings(); self.weeklyCheckInWeekday = 1
        self.clientUpdatedAt = clientUpdatedAt; self.version = 0
    }
    public var sortDate: Date { clientUpdatedAt }
}

// MARK: - Consent

public enum ConsentType: String, Codable, Sendable, CaseIterable {
    /// Terms of use, educational-not-medical acknowledgement, and 18+ attestation.
    case termsAndAge = "terms_and_age"
    /// Store encrypted copies of records on the app's cloud backend.
    case cloudSync = "cloud_sync"
    /// Send minimal health context to the AI provider (Phase 2).
    case aiProcessing = "ai_processing"
    /// Store progress photos in private cloud storage (Phase 2+).
    case progressPhotoStorage = "progress_photo_storage"

    /// Bump when the wording changes; old grants then need re-confirmation.
    public var currentVersion: Int {
        switch self {
        case .termsAndAge: 1
        case .cloudSync: 1
        case .aiProcessing: 1
        case .progressPhotoStorage: 1
        }
    }

    public var title: String {
        switch self {
        case .termsAndAge: "Terms, age and educational use"
        case .cloudSync: "Cloud backup & sync"
        case .aiProcessing: "AI processing of health information"
        case .progressPhotoStorage: "Progress photo storage"
        }
    }

    public var explanation: String {
        switch self {
        case .termsAndAge:
            "I am 18 or older. I understand this app provides education and tracking, not medical diagnosis or treatment, and that I should talk with a clinician before changing any medication."
        case .cloudSync:
            "Back up my records to VitalCoach's private database so they sync across sign-ins. Data is encrypted in transit and at rest, isolated to my account, and never sold or used for advertising. Without this, records stay only on this iPhone."
        case .aiProcessing:
            "Allow the minimum necessary parts of my health records to be sent to the AI provider to generate coaching responses. Not used to train AI models. You can withdraw this at any time."
        case .progressPhotoStorage:
            "Store my progress photos in private, account-isolated cloud storage."
        }
    }
}

/// Append-only consent ledger: grants and withdrawals are separate rows.
public struct ConsentRecord: SyncableRecord {
    public static let entity = EntityName.consentRecords
    public static let isAppendOnly = true
    public var id: UUID
    public var userId: UUID
    public var consentType: ConsentType
    public var granted: Bool
    public var documentVersion: Int
    public var recordedAt: Date
    public var clientUpdatedAt: Date
    public var version: Int
    public var deletedAt: Date?

    public init(id: UUID = UUID(), userId: UUID, consentType: ConsentType, granted: Bool, documentVersion: Int? = nil, recordedAt: Date) {
        self.id = id; self.userId = userId; self.consentType = consentType; self.granted = granted
        self.documentVersion = documentVersion ?? consentType.currentVersion; self.recordedAt = recordedAt
        self.clientUpdatedAt = recordedAt; self.version = 0
    }
    public var sortDate: Date { recordedAt }
    public var indexTag: String? { consentType.rawValue }
}

public struct ConsentState: Sendable, Equatable {
    public var latest: [ConsentType: ConsentRecord]

    public init(records: [ConsentRecord]) {
        var l: [ConsentType: ConsentRecord] = [:]
        for r in records where !r.isDeleted {
            if let existing = l[r.consentType], existing.recordedAt >= r.recordedAt { continue }
            l[r.consentType] = r
        }
        latest = l
    }

    /// Granted *and* for the current document version.
    public func isGranted(_ type: ConsentType) -> Bool {
        guard let r = latest[type] else { return false }
        return r.granted && r.documentVersion >= type.currentVersion
    }
}

// MARK: - Check-ins

public enum BodyLocation: String, Codable, Sendable, CaseIterable, Identifiable {
    case head, neck, shoulderLeft = "shoulder_left", shoulderRight = "shoulder_right"
    case upperBack = "upper_back", lowerBack = "lower_back", chest, abdomen
    case elbowLeft = "elbow_left", elbowRight = "elbow_right", wristHandLeft = "wrist_hand_left", wristHandRight = "wrist_hand_right"
    case hipLeft = "hip_left", hipRight = "hip_right", kneeLeft = "knee_left", kneeRight = "knee_right"
    case ankleFootLeft = "ankle_foot_left", ankleFootRight = "ankle_foot_right", other
    public var id: String { rawValue }
    public var displayName: String {
        var words = rawValue.split(separator: "_").map(String.init)
        var side = ""
        if words.last == "left" { side = " (left)"; words.removeLast() }
        if words.last == "right" { side = " (right)"; words.removeLast() }
        return words.joined(separator: " / ").capitalized.replacingOccurrences(of: "Upper / Back", with: "Upper back")
            .replacingOccurrences(of: "Lower / Back", with: "Lower back") + side
    }
}

public enum FunctionalImpact: String, Codable, Sendable, CaseIterable {
    case none, mild, moderate, severe
    public var displayName: String {
        switch self {
        case .none: "Doesn't limit me"
        case .mild: "Slightly limits activities"
        case .moderate: "Limits many activities"
        case .severe: "Prevents normal activities"
        }
    }
}

/// A daily/weekly check-in. Scores are optional because questions are adaptive;
/// a nil means "not asked", which is different from a low score.
public struct SymptomEntry: SyncableRecord {
    public static let entity = EntityName.symptomEntries
    public var id: UUID
    public var userId: UUID
    public var recordedAt: Date
    public var localDate: LocalDate
    /// 1–5 scales.
    public var wellbeing: Int?
    public var energy: Int?
    public var cognitiveClarity: Int?
    /// 0–10 overall stiffness.
    public var stiffness: Int?
    public var mobilityLimitations: String?
    public var sideEffectsNote: String?
    public var note: String?
    public var isWeekly: Bool
    /// Version of the question set, so longitudinal comparisons use the same questions.
    public var questionSetVersion: Int
    public var clientUpdatedAt: Date
    public var version: Int
    public var deletedAt: Date?

    public init(id: UUID = UUID(), userId: UUID, recordedAt: Date, localDate: LocalDate, isWeekly: Bool = false,
                questionSetVersion: Int = CheckInPlanner.questionSetVersion) {
        self.id = id; self.userId = userId; self.recordedAt = recordedAt; self.localDate = localDate
        self.isWeekly = isWeekly; self.questionSetVersion = questionSetVersion
        self.clientUpdatedAt = recordedAt; self.version = 0
    }
    public var sortDate: Date { recordedAt }
}

public struct PainEntry: SyncableRecord {
    public static let entity = EntityName.painEntries
    public var id: UUID
    public var userId: UUID
    public var symptomEntryId: UUID?
    public var recordedAt: Date
    public var location: BodyLocation
    public var locationDetail: String?
    /// 0–10 numeric rating scale.
    public var severity: Int
    public var stiffness: Int?
    public var functionalImpact: FunctionalImpact?
    public var note: String?
    public var clientUpdatedAt: Date
    public var version: Int
    public var deletedAt: Date?

    public enum ValidationError: Error, Equatable, Sendable { case severityOutOfRange, stiffnessOutOfRange }

    public init(id: UUID = UUID(), userId: UUID, symptomEntryId: UUID?, recordedAt: Date, location: BodyLocation,
                severity: Int, stiffness: Int? = nil, functionalImpact: FunctionalImpact? = nil,
                locationDetail: String? = nil, note: String? = nil) throws {
        guard (0...10).contains(severity) else { throw ValidationError.severityOutOfRange }
        if let s = stiffness, !(0...10).contains(s) { throw ValidationError.stiffnessOutOfRange }
        self.id = id; self.userId = userId; self.symptomEntryId = symptomEntryId; self.recordedAt = recordedAt
        self.location = location; self.locationDetail = locationDetail; self.severity = severity
        self.stiffness = stiffness; self.functionalImpact = functionalImpact; self.note = note
        self.clientUpdatedAt = recordedAt; self.version = 0
    }
    public var sortDate: Date { recordedAt }
    public var indexTag: String? { location.rawValue }
}

// MARK: - Audit

public struct AuditEvent: SyncableRecord {
    public static let entity = EntityName.auditEvents
    public static let isAppendOnly = true
    public var id: UUID
    public var userId: UUID
    public var targetEntity: EntityName
    public var targetId: UUID
    public var action: String
    /// Short, non-sensitive description (e.g. "status active → paused"). No free-text notes.
    public var summary: String
    public var occurredAt: Date
    public var clientUpdatedAt: Date
    public var version: Int
    public var deletedAt: Date?

    public init(id: UUID = UUID(), userId: UUID, targetEntity: EntityName, targetId: UUID, action: String, summary: String, occurredAt: Date) {
        self.id = id; self.userId = userId; self.targetEntity = targetEntity; self.targetId = targetId
        self.action = action; self.summary = summary; self.occurredAt = occurredAt
        self.clientUpdatedAt = occurredAt; self.version = 0
    }
    public var sortDate: Date { occurredAt }
    public var indexTag: String? { targetId.uuidString }
}
