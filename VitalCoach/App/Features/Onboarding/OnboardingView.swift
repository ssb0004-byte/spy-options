import SwiftUI
import VitalCore

/// Progressive onboarding: only consent and goals are required. Every other step explains why
/// it's asked and can be skipped; skipped items resurface later on the Profile tab.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                    VitalBrandLockup(markSize: 36)
                    stepView(model.nextOnboardingStep)
                    // Parent-company attribution: onboarding footer only (see docs/design/BRAND.md).
                    Text("VitalCoach Health · A PrecisionPeptidePens company")
                        .vitalFont(.caption).foregroundStyle(VitalColors.textSecondary)
                        .frame(maxWidth: .infinity)
                }
                .padding(Theme.Spacing.xl)
                .frame(maxWidth: 600)
                .frame(maxWidth: .infinity)
            }
            .background(Theme.pageBackground)
            .animation(reduceMotion ? nil : .default, value: model.nextOnboardingStep)
        }
    }

    @ViewBuilder
    private func stepView(_ step: OnboardingStep) -> some View {
        switch step {
        case .welcome: WelcomeStep()
        case .consent: ConsentStep()
        case .name: NameStep()
        case .goals: GoalsStep()
        case .units: UnitsStep()
        case .basics: BasicsStep()
        case .healthKit: HealthKitStep()
        case .cloudSync: CloudSyncStep()
        case .coachStyle: CoachStyleStep()
        case .done: DoneStep()
        }
    }
}

/// Shared header/footer for steps.
private struct StepScaffold<Content: View>: View {
    @Environment(AppModel.self) var model
    var step: OnboardingStep
    var title: String
    var why: String?
    var continueTitle = "Continue"
    var canContinue = true
    var onContinue: () async -> Void
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            Text(title).vitalFont(.title).foregroundStyle(VitalColors.textPrimary).accessibilityAddTraits(.isHeader)
            if let why { Text(why).vitalFont(.body).foregroundStyle(VitalColors.textSecondary) }
            content
            Button {
                Task {
                    await onContinue()
                    model.onboarding.complete(step)
                    model.saveOnboarding()
                }
            } label: {
                Text(continueTitle)
            }
            .buttonStyle(VitalButtonStyle(kind: .primary))
            .disabled(!canContinue)
            .accessibilityIdentifier("onboarding.continue")
            if !step.isRequired {
                Button("Skip for now") {
                    model.onboarding.skip(step)
                    model.saveOnboarding()
                }
                .buttonStyle(VitalButtonStyle(kind: .tertiary))
            }
        }
    }
}

private struct WelcomeStep: View {
    var body: some View {
        StepScaffold(step: .welcome, title: "Welcome", why: nil, continueTitle: "Get started", onContinue: {}) {
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                Label("Track body composition, vitals and how you feel", systemImage: "chart.xyaxis.line")
                Label("Keep an accurate log of medications and supplements", systemImage: "pills")
                Label("Your data stays private and is never sold", systemImage: "lock.shield")
            }
            .font(.body)
            Text("Setup takes about two minutes. Only two steps are required; the rest can wait.")
                .font(.footnote).foregroundStyle(VitalColors.textSecondary)
        }
    }
}

private struct ConsentStep: View {
    @Environment(AppModel.self) private var model
    @State private var agreed = false

    var body: some View {
        StepScaffold(step: .consent, title: "Before we start",
                     why: "VitalCoach helps you track and understand your health. It doesn't diagnose conditions or replace your clinician.",
                     continueTitle: "I agree", canContinue: agreed,
                     onContinue: { await model.setConsent(.termsAndAge, granted: true) }) {
            Card {
                Text(ConsentType.termsAndAge.explanation).font(.callout)
                Toggle("I am 18 or older and agree", isOn: $agreed)
                    .font(.callout.weight(.medium))
            }
            NoticeBanner(style: .critical, text: "If you have a medical emergency, call your local emergency number (911 in the US).")
        }
    }
}

private struct NameStep: View {
    @Environment(AppModel.self) private var model
    @State private var name = ""

    var body: some View {
        StepScaffold(step: .name, title: "What should we call you?", why: "Used only for greetings in the app.",
                     onContinue: {
                         guard var p = model.data.profile else { return }
                         p.displayName = name.trimmingCharacters(in: .whitespaces).isEmpty ? nil : String(name.prefix(100))
                         await model.save(p)
                     }) {
            TextField("First name or nickname", text: $name)
                .textContentType(.givenName)
                .textFieldStyle(.roundedBorder)
        }
    }
}

private struct GoalsStep: View {
    @Environment(AppModel.self) private var model
    @State private var selected: Set<HealthGoal> = []

    var body: some View {
        StepScaffold(step: .goals, title: "What are you working toward?",
                     why: "Pick any that apply — no need to rank them. Goals decide which trends and check-in questions you see. You can change them anytime.",
                     canContinue: !selected.isEmpty,
                     onContinue: { await model.setGoals(selected) }) {
            GoalPicker(selected: $selected)
        }
        .onAppear { selected = Set(model.data.activeGoals) }
    }
}

struct GoalPicker: View {
    @Binding var selected: Set<HealthGoal>

    var body: some View {
        VStack(spacing: Theme.Spacing.s) {
            ForEach(HealthGoal.allCases) { goal in
                Button {
                    if selected.contains(goal) { selected.remove(goal) } else { selected.insert(goal) }
                } label: {
                    HStack {
                        Image(systemName: goal.symbolName).frame(width: 28).accessibilityHidden(true)
                        Text(goal.displayName)
                        Spacer()
                        Image(systemName: selected.contains(goal) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selected.contains(goal) ? Theme.accent : .secondary)
                            .accessibilityHidden(true)
                    }
                    .padding(Theme.Spacing.m)
                    .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected.contains(goal) ? [.isSelected] : [])
            }
        }
    }
}

private struct UnitsStep: View {
    @Environment(AppModel.self) private var model
    @State private var units: UnitSystem = .metric

    var body: some View {
        StepScaffold(step: .units, title: "Units", why: "Values are stored precisely; this only changes how they're shown.",
                     onContinue: {
                         guard var p = model.data.preferences else { return }
                         p.unitSystem = units
                         await model.save(p)
                     }) {
            Picker("Units", selection: $units) {
                Text("Metric (kg, cm)").tag(UnitSystem.metric)
                Text("Imperial (lb, in)").tag(UnitSystem.imperial)
            }
            .pickerStyle(.segmented)
        }
        .onAppear { units = model.data.units }
    }
}

private struct BasicsStep: View {
    @Environment(AppModel.self) private var model
    @State private var hasDOB = false
    @State private var dob = Calendar.current.date(byAdding: .year, value: -35, to: Date()) ?? Date()
    @State private var heightText = ""
    @State private var sex: PhysiologicalSex?
    @State private var activity: ActivityLevel?

    private var ageProblem: Bool {
        hasDOB && !AgeGate.isAdult(dateOfBirth: LocalDate(dob, calendar: .current), now: Date(), calendar: .current)
    }

    var body: some View {
        StepScaffold(step: .basics, title: "A few basics",
                     why: "Age, height and physiological sex change how some measurements are interpreted (for example BMI and reference ranges). All optional.",
                     canContinue: !ageProblem,
                     onContinue: save) {
            Card {
                Toggle("Add date of birth", isOn: $hasDOB)
                if hasDOB {
                    DatePicker("Date of birth", selection: $dob, in: ...Date(), displayedComponents: .date)
                }
                if ageProblem {
                    NoticeBanner(style: .warning, text: "VitalCoach is only available to adults 18 and older.")
                }
                HStack {
                    Text("Height")
                    TextField(model.data.units == .metric ? "cm" : "inches", text: $heightText)
                        .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                }
                Picker("Physiological sex", selection: $sex) {
                    Text("Not set").tag(PhysiologicalSex?.none)
                    ForEach(PhysiologicalSex.allCases, id: \.self) { Text($0.displayName).tag(PhysiologicalSex?.some($0)) }
                }
                Picker("Activity level", selection: $activity) {
                    Text("Not set").tag(ActivityLevel?.none)
                    ForEach(ActivityLevel.allCases, id: \.self) { Text($0.displayName).tag(ActivityLevel?.some($0)) }
                }
            }
        }
    }

    private func save() async {
        guard var p = model.data.profile else { return }
        if hasDOB { p.dateOfBirth = LocalDate(dob, calendar: .current) }
        if let h = Double(heightText.replacingOccurrences(of: ",", with: ".")) {
            let cm = model.data.units.length.toCentimeters(h)
            if (100...250).contains(cm) { p.heightCm = cm }
        }
        p.physiologicalSex = sex
        p.activityLevel = activity
        await model.save(p)
    }
}

private struct HealthKitStep: View {
    @Environment(AppModel.self) private var model
    @State private var selected: Set<MetricKind> = [.bodyMass, .bodyFatPercentage, .leanBodyMass, .bodyMassIndex]

    var body: some View {
        StepScaffold(step: .healthKit, title: "Connect Apple Health",
                     why: "Read-only. If you use an Arboleaf scale, its app saves weight and body-composition estimates to Apple Health, and VitalCoach reads them from there. Choose exactly what to share; iOS will ask you to confirm.",
                     continueTitle: "Choose in Apple Health", canContinue: !selected.isEmpty,
                     onContinue: { await model.requestHealthAccess(Array(selected)) }) {
            Card {
                ForEach(HealthKitCatalog.entries, id: \.kind) { entry in
                    Toggle(entry.kind.displayName, isOn: Binding(
                        get: { selected.contains(entry.kind) },
                        set: { if $0 { selected.insert(entry.kind) } else { selected.remove(entry.kind) } }))
                }
            }
            Text("iOS doesn't tell apps whether you allowed reading. VitalCoach shows a category as connected only after data actually arrives.")
                .font(.footnote).foregroundStyle(VitalColors.textSecondary)
        }
    }
}

private struct CloudSyncStep: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.isLocalOnly || model.backend == nil {
            Color.clear.onAppear {
                model.onboarding.skip(.cloudSync)
                model.saveOnboarding()
            }
        } else {
            StepScaffold(step: .cloudSync, title: "Back up and sync",
                         why: ConsentType.cloudSync.explanation, continueTitle: "Turn on backup",
                         onContinue: { await model.setConsent(.cloudSync, granted: true) }) {
                Text("You can turn this off later in Profile → Privacy. Turning it off stops uploads; it doesn't delete what's already stored (use Delete account for that).")
                    .font(.footnote).foregroundStyle(VitalColors.textSecondary)
            }
        }
    }
}

private struct CoachStyleStep: View {
    @Environment(AppModel.self) private var model
    @State private var style: CoachPersonality = .balanced

    var body: some View {
        StepScaffold(step: .coachStyle, title: "Coaching style",
                     why: "How should your coach talk to you? This only changes tone, never the facts. The AI coach arrives in a later update.",
                     onContinue: {
                         guard var p = model.data.preferences else { return }
                         p.coachPersonality = style
                         await model.save(p)
                     }) {
            Picker("Style", selection: $style) {
                ForEach(CoachPersonality.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
        .onAppear { style = model.data.preferences?.coachPersonality ?? .balanced }
    }
}

private struct DoneStep: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        StepScaffold(step: .done, title: "You're set", why: "Next: add what you take in the Routine tab, and log a check-in when you're ready.",
                     continueTitle: "Go to my dashboard", onContinue: {
                         _ = await model.notifications.requestAuthorization()
                         await model.finishOnboarding()
                     }) {
            if !model.onboarding.deferredPrompts.isEmpty {
                Text("You skipped a few optional steps. You'll find them on your Profile tab whenever you want.")
                    .font(.footnote).foregroundStyle(VitalColors.textSecondary)
            }
        }
    }
}
