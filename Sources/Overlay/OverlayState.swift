import Foundation

/// The Overlay's visible states (docs/04-hld.md §13.1 — "Overlay & Menubar UI").
///
/// The Overlay is the non-activating panel that reports what Aide is doing without
/// stealing focus. Its state machine is the deep, testable heart of the subsystem;
/// the panel (`App/OverlayPanel.swift`) is a thin view shell bound to these states.
///
/// States (verbatim from the HLD state diagram):
/// - `hidden`:        off-screen; the resting state.
/// - `listening`:     mic is hot (Push-to-Talk down / wake word) — Listening State feedback.
/// - `processing`:    Push-to-Talk released; transcribing / routing.
/// - `showingResult`: the dispatch outcome (skill result / answer) is on screen.
/// - `promptBack`:    a non-destructive "did you mean…?" (null skill / low confidence).
/// - `confirmBack`:   a Risk-Tier confirmation (marginal `confirm` / `always_confirm`).
public enum OverlayState: String, CaseIterable, Sendable, Equatable {
    case hidden
    case listening
    case processing
    case showingResult
    case promptBack
    case confirmBack

    /// The resting state a fresh machine starts in.
    public static let initial: OverlayState = .hidden

    /// Whether the panel is on-screen in this state (everything except `hidden`).
    public var isVisible: Bool { self != .hidden }

    /// A short human-readable label (used by the temporary Phase-4 debug menu).
    public var displayName: String {
        switch self {
        case .hidden: return "Hidden"
        case .listening: return "Listening"
        case .processing: return "Processing"
        case .showingResult: return "Showing Result"
        case .promptBack: return "Prompt-Back"
        case .confirmBack: return "Confirm-Back"
        }
    }
}

/// The events that drive Overlay transitions (docs/04-hld.md §13.1).
///
/// Each event maps 1:1 to a labelled edge in the HLD state diagram, plus the
/// Push-to-Talk flow-control rule from docs/05-lld.md §10 ("a new hotkey press while
/// `Processing` cancels the prior in-flight Task and starts fresh"), modelled here as
/// `activate` being legal again from `processing`.
public enum OverlayEvent: String, CaseIterable, Sendable, Equatable {
    /// PTT down / wake word — begin (or restart) a listening session.
    case activate
    /// PTT up — the utterance is complete; begin transcribing / routing.
    case beginProcessing
    /// Dispatch outcome ready — show the result / answer.
    case presentResult
    /// `skill_id` null or low confidence — ask "did you mean…?".
    case presentPromptBack
    /// Risk-Tier `confirm` (marginal) / `always_confirm` — ask the user to confirm.
    case presentConfirmBack
    /// Dismiss / timeout (result) or resolved / cancel (prompt-back) — return to hidden.
    case dismiss
    /// Confirm-Back approved — proceed to show the result.
    case approve
    /// Confirm-Back rejected — abort and return to hidden.
    case reject
}
