import Onboarding
import SwiftUI

/// The Onboarding window's root view (Phase 10): a thin router from
/// `coordinator.onboardingFlow?.currentStep` to the matching step view. Owns no
/// flow logic itself — every step view mutates the flow only through
/// `AppCoordinator`'s `onboarding*` methods, which persist progress as they go
/// (`AppCoordinator.syncOnboardingProgress`).
struct OnboardingRootView: View {
    @ObservedObject var coordinator: AppCoordinator

    var body: some View {
        Group {
            if let step = coordinator.onboardingFlow?.currentStep {
                stepView(for: step)
            }
        }
        .padding(28)
        .frame(width: 480, height: 380, alignment: .topLeading)
    }

    @ViewBuilder
    private func stepView(for step: OnboardingStep) -> some View {
        switch step {
        case .welcome:
            OnboardingWelcomeStep(coordinator: coordinator)
        case .tier:
            OnboardingTierStep(coordinator: coordinator)
        case .permissionMicrophone, .permissionAccessibility, .permissionInputMonitoring,
            .permissionScreenRecording, .permissionCalendar:
            if let permission = step.permission {
                OnboardingPermissionStep(coordinator: coordinator, permission: permission)
            }
        case .disclosure:
            OnboardingDisclosureStep(coordinator: coordinator)
        case .hotkeys:
            OnboardingHotkeysStep(coordinator: coordinator)
        case .firstSuccess:
            OnboardingFirstSuccessStep(coordinator: coordinator)
        case .summary:
            OnboardingSummaryStep(coordinator: coordinator)
        }
    }
}
