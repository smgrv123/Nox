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
    case screenRecording
    case calendar

    /// Human-readable name for menubar / Settings surfaces.
    public var displayName: String {
        switch self {
        case .microphone: return "Microphone"
        case .accessibility: return "Accessibility"
        case .screenRecording: return "Screen Recording"
        case .calendar: return "Calendar"
        }
    }

    /// Whether the permission is skippable during onboarding (LLD §8: Calendar is
    /// optional; the rest are load-bearing for core features).
    public var isOptional: Bool { self == .calendar }

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
        case .screenRecording: return "Privacy_ScreenCapture"
        case .calendar: return "Privacy_Calendars"
        }
    }
}
