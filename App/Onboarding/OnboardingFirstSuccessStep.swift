import Configuration
import Overlay
import Permissions
import SwiftUI

/// Guided first success (User Story 23). Deliberately does **not** re-drive the
/// voice loop itself: `AppCoordinator` already installs the global hotkey tap at
/// launch (Phase 5) and wires it straight through to the Phase-6 mock
/// `VoiceSessionCoordinator` → Overlay loop, regardless of onboarding — pressing the
/// real hotkey here exercises the exact same path a normal press would. All this
/// step adds is the coaching copy and watching `coordinator.overlay.state` so
/// "Continue" only lights up once the user has actually seen a result — proof the
/// loop ran, not just a click-through.
///
/// By the time the user reaches this step every **required** permission
/// (Microphone, Accessibility, Input Monitoring, Screen Recording) is already
/// granted — those steps don't advance otherwise — so the hotkey and mic are
/// guaranteed to work (Input Monitoring is what lets the global hotkey tap fire).
struct OnboardingFirstSuccessStep: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject private var overlay: OverlayController
    @Environment(\.openURL) private var openURL
    @State private var sawResult = false
    // Refreshed in `.onAppear` and on "Retry": true iff the global push-to-talk tap is
    // really installed. Onboarding normally guarantees Input Monitoring is granted by this
    // step, but a grant can go stale for a fresh build — without this the "Try It" step
    // would hard-block on a hotkey that can never fire, with no way out.
    @State private var tapInstalled = false

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        self.overlay = coordinator.overlay
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Try It")
                .font(.title.bold())

            (Text("Hold **\(coordinator.settings.hotkeys.commandMode.displayString)** ")
                + Text("and say something — anything. Release when you're done talking."))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if sawResult {
                Label("You just talked to Aide.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }

            Spacer()

            // Recovery affordance: the hotkey tap isn't live, so the success path below can
            // never fire — offer a way to re-grant Input Monitoring instead of a dead-ended
            // "Waiting…" button. Shown *instead of* the inert waiting affordance; once the
            // tap is installed (or a result was somehow already seen) the normal path resumes.
            if !tapInstalled && !sawResult {
                VStack(alignment: .leading, spacing: 8) {
                    Text(
                        "Aide can't capture your hotkey yet — Input Monitoring may need to be "
                            + "granted for this build."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                    HStack {
                        Button("Open Input Monitoring Settings") {
                            openURL(Permission.inputMonitoring.settingsDeepLink)
                        }
                        Button("Retry") {
                            coordinator.recheckInputMonitoring()
                            tapInstalled = coordinator.hotkeys.isTapInstalled
                        }
                    }
                }
            } else {
                HStack {
                    Spacer()
                    Button(sawResult ? "Continue" : "Waiting for your first try…") {
                        coordinator.onboardingAdvance()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!sawResult)
                }
            }
        }
        .onAppear { tapInstalled = coordinator.hotkeys.isTapInstalled }
        .onChange(of: overlay.state) { _, newState in
            if newState == .showingResult {
                sawResult = true
            }
        }
    }
}
