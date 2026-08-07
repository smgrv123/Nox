import Foundation

/// The four macOS TCC permissions Aide can use, each detected **independently and
/// prompt-free** (User Story 27; docs/05-lld.md §8). This type is the pure, testable
/// contract: it owns the exact System Settings deep-link and the set of features each
/// permission gates. The effectful status query (AVFoundation / AX / CoreGraphics /
/// EventKit) is a thin shell in the app target (`App/SystemPermissionReader.swift`),
/// kept out of this module so the logic stays headless-testable.
public enum Permission: String, CaseIterable, Sendable {
    case microphone
    case accessibility
    case inputMonitoring
    case screenRecording
    case calendar

    /// Human-readable name for menubar / Settings surfaces.
    public var displayName: String {
        switch self {
        case .microphone: return "Microphone"
        case .accessibility: return "Accessibility"
        case .inputMonitoring: return "Input Monitoring"
        case .screenRecording: return "Screen Recording"
        case .calendar: return "Calendar"
        }
    }

    /// Whether the permission is skippable during onboarding (LLD §8: Calendar is
    /// optional; the rest are load-bearing for core features).
    public var isOptional: Bool { self == .calendar }

    /// Whether a fresh grant of this permission is only reflected by macOS **after Aide
    /// relaunches** — true for Screen Recording only. `CGPreflightScreenCaptureAccess()`
    /// (what `SystemPermissionReader` reads for `.screenRecording`) keeps returning
    /// `false` for the rest of the granting app's session even after the user flips the
    /// toggle in System Settings; the OS only picks the new grant up on the app's next
    /// launch. Onboarding uses this to offer an honest "Continue" affordance instead of
    /// hard-blocking the user on a poll that can never observe `.granted` in-session (see
    /// `OnboardingFlow.proceedPastRelaunchGatedPermission()`).
    public var grantTakesEffectAfterRelaunch: Bool { self == .screenRecording }

    /// Whether Aide can trigger this permission's grant prompt **in-app** (a `requestAccess`
    /// API), versus only guiding the user to System Settings. Accessibility has no such
    /// prompt — it "cannot be prompted programmatically — must guide + deep-link" (LLD §8).
    /// The other three (Microphone, Screen Recording, Calendar) aren't even *listed* under
    /// System Settings → Privacy until the app has requested once, so onboarding requests
    /// them directly rather than deep-linking to a pane that wouldn't yet show Aide.
    public var canRequestInApp: Bool {
        switch self {
        case .accessibility: return false
        case .microphone, .inputMonitoring, .screenRecording, .calendar: return true
        }
    }

    /// Whether onboarding should offer this permission's **in-app** grant prompt (vs. a
    /// deep-link to System Settings) given its current status. Centralizes the one wrinkle
    /// in that choice: Screen Recording's status comes from `CGPreflightScreenCaptureAccess()`
    /// — a bare `Bool` — so `SystemPermissionReader` can only ever map it to `.granted` or
    /// `.denied`, never `.notDetermined` (unlike Microphone/Calendar, which genuinely report
    /// it via their `AVAuthorizationStatus`/`EKAuthorizationStatus`). Requesting again after
    /// an explicit `.denied` silently no-ops for those two, so they should only be offered
    /// the prompt pre-decision (`.notDetermined`) and fall back to the deep-link once denied
    /// (or restricted). Screen Recording's request is itself the registration step — the
    /// only call that both shows the system prompt *and* lists Aide under System Settings —
    /// and is safe/idempotent to call repeatedly, so it should be offered any time the
    /// permission isn't already granted. `grantTakesEffectAfterRelaunch` is true for exactly
    /// this one Bool-preflight permission, so it doubles as the signal here.
    public func offersInAppRequest(at status: PermissionStatus) -> Bool {
        guard canRequestInApp else { return false }
        if grantTakesEffectAfterRelaunch {
            return status != .granted
        }
        return status == .notDetermined
    }

    /// The System Settings > Privacy & Security pane that this permission lives in,
    /// used verbatim in fix-it hints.
    public var settingsPaneName: String {
        "Privacy & Security → \(displayName)"
    }

    /// What the user loses while the permission is missing — the "why it matters" half
    /// of the fix-it hint (User Story 26), constant per permission.
    public var deniedConsequence: String {
        switch self {
        case .microphone:
            return "Aide can't hear you, so voice commands and dictation are off."
        case .accessibility:
            return "Aide's global hotkeys and text insertion can't work."
        case .inputMonitoring:
            return "Aide's global push-to-talk hotkey won't work."
        case .screenRecording:
            return "Aide can't read your screen, so Screen Q&A is off."
        case .calendar:
            return "Aide can't read your calendar, so schedule questions are off."
        }
    }

    /// Deep-link that opens the **exact** System Settings pane for this permission
    /// (LLD §8). Re-granting there recovers the dependent features.
    public var settingsDeepLink: URL {
        // Constant literal built from a fixed anchor — never nil.
        // swiftlint:disable:next force_unwrapping
        URL(string: "x-apple.systempreferences:com.apple.preference.security?\(privacyAnchor)")!
    }

    /// The features this permission gates — the per-permission **degradation map**
    /// (LLD §8). Denying the permission disables exactly these and nothing else.
    /// Derived from `Feature.requiredPermission` so the mapping has a single source of truth.
    public var gatedFeatures: Set<Feature> {
        Set(Feature.allCases.filter { $0.requiredPermission == self })
    }

    /// The `Privacy_*` anchor appended to the Security pref pane URL (LLD §8).
    private var privacyAnchor: String {
        switch self {
        case .microphone: return "Privacy_Microphone"
        case .accessibility: return "Privacy_Accessibility"
        case .inputMonitoring: return "Privacy_ListenEvent"
        case .screenRecording: return "Privacy_ScreenCapture"
        case .calendar: return "Privacy_Calendars"
        }
    }
}
