import Foundation

/// A capability that depends on a TCC permission. Each feature is gated by **exactly
/// one** `Permission` (LLD §8), which makes graceful degradation a clean partition:
/// denying a permission disables precisely the features that require it.
///
/// This inverse map (`feature → permission`) is the single source of truth; the
/// forward map (`permission → features`) is derived in `Permission.gatedFeatures`.
public enum Feature: String, CaseIterable, Sendable {
    /// Command Mode speech-to-text (Microphone).
    case commandMode
    /// Dictation Mode speech-to-text (Microphone).
    case dictationMode
    /// Wake-word listening (Microphone).
    case wakeWord
    /// AX-path text insertion (Accessibility).
    case textInsertion
    /// Global push-to-talk hotkey via `CGEventTap` (Input Monitoring).
    case hotkeyCapture
    /// Screen Q&A via `screencapture` (Screen Recording).
    case screenQA
    /// Calendar-read skill (Calendar / EventKit — optional).
    case calendarSkill

    /// The permission that must be granted for this feature to work (LLD §8 table).
    public var requiredPermission: Permission {
        switch self {
        case .commandMode, .dictationMode, .wakeWord: return .microphone
        case .textInsertion: return .accessibility
        case .hotkeyCapture: return .inputMonitoring
        case .screenQA: return .screenRecording
        case .calendarSkill: return .calendar
        }
    }

    /// Human-readable name for degradation summaries.
    public var displayName: String {
        switch self {
        case .commandMode: return "Command Mode"
        case .dictationMode: return "Dictation Mode"
        case .wakeWord: return "Wake Word"
        case .textInsertion: return "Text Insertion"
        case .hotkeyCapture: return "Global Hotkeys"
        case .screenQA: return "Screen Q&A"
        case .calendarSkill: return "Calendar Skill"
        }
    }
}
