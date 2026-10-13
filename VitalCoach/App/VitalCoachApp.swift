import Combine
import SwiftUI
import VitalCore

@main
struct VitalCoachApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    init() { Theme.applyAppearance() }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .tint(VitalColors.accent)
                .task { await model.launch() }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active, model.phase == .ready else { return }
                    Task {
                        await model.reload()
                        await model.refreshReminders()
                        model.scheduleSync(after: 0)
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in
                    // Wall-clock schedules follow the device zone; re-plan reminders after travel.
                    Task { await model.refreshReminders() }
                }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            switch model.phase {
            case .launching:
                VStack(spacing: VitalSpacing.m) {
                    VitalLogoMark(size: 72)
                    ProgressView().tint(VitalColors.accent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .vitalScreenBackground()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Loading your data")
            case .signedOut:
                SignInView()
            case .ready:
                if model.needsOnboarding { OnboardingView() } else { MainTabView() }
            }
        }
        .alert("Something went wrong", isPresented: Binding(get: { model.lastError != nil }, set: { if !$0 { model.lastError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.lastError ?? "")
        }
    }
}

struct MainTabView: View {
    var body: some View {
        TabView {
            Tab("Home", systemImage: "house") { HomeView() }
            Tab("Trends", systemImage: "chart.xyaxis.line") { TrendsView() }
            Tab("Routine", systemImage: "pills") { RoutineView() }
            Tab("Coach", systemImage: "bubble.left.and.text.bubble.right") { CoachView() }
            Tab("Profile", systemImage: "person.crop.circle") { SettingsView() }
        }
    }
}
