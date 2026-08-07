import Permissions
import SwiftUI

/// One "why + deep-link + status" screen per permission (User Stories 18–21).
/// Reads through `coordinator.permissionGate` — the one `PermissionGate`
/// `AppCoordinator` owns (docs/05-lld.md §8), the same single source
/// `PermissionsPane` reads — rather than constructing its own. Auto-advance on a
/// detected grant is driven by `AppCoordinator` (polling + `applicationDidBecomeActive`);
/// "Re-check" here just gives the user an immediate, explicit way to trigger the same check.
struct OnboardingPermissionStep: View {
    @ObservedObject var coordinator: AppCoordinator
    let permission: Permission

    @Environment(\.openURL) private var openURL
    @State private var status: PermissionStatus = .notDetermined
    @State private var tapInstalled: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(permission.displayName)
                .font(.title.bold())

            Text(permission.deniedConsequence)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            PermissionStatusBadge(
                status: status,
                denied: "Not Granted Yet",
                notDetermined: "Not Granted Yet",
                restricted: "Restricted by System Policy")

            // macOS can report Input Monitoring as granted while tap creation is still denied
            // (e.g. a stale grant after a dev rebuild): the badge reads green but the step
            // won't advance because the hotkey can't be captured. Explain the mismatch and
            // the fix rather than leaving the user staring at a stuck "granted" screen.
            if permission == .inputMonitoring && status == .granted && !tapInstalled {
                Text(
                    "macOS shows Input Monitoring as granted, but Aide still can't capture your "
                        + "hotkey yet. Quit and reopen Aide, then press Re-check."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            // State-aware grant affordance (LLD §8): a permission Aide can request in-app
            // that hasn't been decided yet gets the native system prompt — the only way
            // Microphone/Screen Recording/Calendar even appear under System Settings. Once
            // explicitly denied (or for Accessibility, which has no in-app prompt) fall back
            // to the deep-link, by which point the app is listed and can be toggled.
            // `Permission.offersInAppRequest(at:)` centralizes the one exception: Screen
            // Recording's Bool-only preflight can never report `.notDetermined`, so it offers
            // the request (its request call is also the registration step) any time it isn't
            // already granted, instead of gating on `.notDetermined` like Microphone/Calendar.
            if permission.offersInAppRequest(at: status) {
                Button("Allow \(permission.displayName) Access…") {
                    coordinator.requestOnboardingPermission { refresh() }
                }
            } else {
                Button("Open \(permission.displayName) Settings…") {
                    openURL(permission.settingsDeepLink)
                }
            }

            // macOS never reflects a fresh grant of a relaunch-gated permission (Screen
            // Recording) within this app session (`Permission.grantTakesEffectAfterRelaunch`),
            // so the auto-advance poll can never see `.granted` here — without this, granting
            // it would still hard-stall onboarding. Offer an honest, explicit way past the
            // step instead of a bypass that could be mistaken for a real grant check; granting
            // above still registers Aide for a later session, where auto-advance will already
            // have passed this step on relaunch.
            if permission.grantTakesEffectAfterRelaunch {
                VStack(alignment: .leading, spacing: 4) {
                    Text(
                        "\(permission.displayName) takes effect the next time Aide starts — "
                            + "you can finish setup now."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    Button("Continue") {
                        coordinator.onboardingProceedPastRelaunchGatedPermission()
                    }
                }
            }

            Spacer()

            HStack {
                if permission.isOptional {
                    Button("Skip") { coordinator.onboardingSkip() }
                }
                Spacer()
                Button("Re-check") {
                    refresh()
                    coordinator.recheckOnboardingPermission()
                }
            }
        }
        .onAppear { refresh() }
    }

    private func refresh() {
        status = coordinator.permissionGate.status(for: permission)
        tapInstalled = coordinator.hotkeys.isTapInstalled
    }
}
