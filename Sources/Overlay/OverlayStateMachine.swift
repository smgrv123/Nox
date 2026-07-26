import Foundation

/// The Overlay's pure, guarded state machine (docs/04-hld.md §13.1).
///
/// No UI, no I/O — the deep, headlessly-testable core of the Overlay subsystem
/// (specs/P1 §"Modules"; the pattern mirrors `SingleInstanceGuard`). The panel in
/// `App/OverlayPanel.swift` owns one of these and renders `state`; the Phase-6 voice
/// driver will feed it `OverlayEvent`s.
///
/// **Guards (MUST):** only the transitions in `table` are legal. Any other
/// `(state, event)` pair is rejected — the state is left unchanged. This is the
/// property the test suite pins down exhaustively.
public struct OverlayStateMachine: Sendable, Equatable {

    /// The current state. Mutated only through `send`, or seeded via `init`.
    public private(set) var state: OverlayState

    /// Create a machine at a starting state (defaults to `.hidden`, the resting state).
    /// A non-default start state exists so tests can exercise every transition in
    /// isolation, and so the panel's temporary debug controls can jump directly to a
    /// state for visual verification.
    public init(state: OverlayState = .initial) {
        self.state = state
    }

    /// One directed edge of the Overlay graph — the key into the transition `table`.
    private struct Edge: Hashable, Sendable {
        let from: OverlayState
        let event: OverlayEvent
    }

    /// The legal transition table — **data, not control flow**. Its entries are
    /// exactly the edges of the HLD §13.1 diagram, plus the Push-to-Talk restart edge
    /// (`processing --activate--> listening`) from LLD §10 ("a new hotkey press while
    /// `Processing` cancels the prior in-flight Task and starts fresh"). Every pair
    /// absent from this table is illegal — the guard rejects it.
    private static let table: [Edge: OverlayState] = [
        // Hidden --PTT down / wake word--> Listening
        Edge(from: .hidden, event: .activate): .listening,
        // Listening --PTT up--> Processing
        Edge(from: .listening, event: .beginProcessing): .processing,
        // Processing --dispatch outcome--> ShowingResult
        Edge(from: .processing, event: .presentResult): .showingResult,
        // Processing --skill_id null / low confidence--> PromptBack
        Edge(from: .processing, event: .presentPromptBack): .promptBack,
        // Processing --Risk-Tier confirm / always_confirm--> ConfirmBack
        Edge(from: .processing, event: .presentConfirmBack): .confirmBack,
        // Processing --new PTT press cancels & restarts--> Listening (LLD §10 flow control)
        Edge(from: .processing, event: .activate): .listening,
        // ShowingResult --dismiss / timeout--> Hidden
        Edge(from: .showingResult, event: .dismiss): .hidden,
        // PromptBack --resolved / cancel--> Hidden
        Edge(from: .promptBack, event: .dismiss): .hidden,
        // ConfirmBack --approved--> ShowingResult
        Edge(from: .confirmBack, event: .approve): .showingResult,
        // ConfirmBack --rejected--> Hidden
        Edge(from: .confirmBack, event: .reject): .hidden,
    ]

    /// The destination for a *legal* `(state, event)` pair, or `nil` when the
    /// transition is illegal (guarded). Pure — a plain lookup in `table`.
    public static func destination(from state: OverlayState, on event: OverlayEvent) -> OverlayState? {
        table[Edge(from: state, event: event)]
    }

    /// Apply an event.
    ///
    /// - Returns: `true` if the event was a legal transition (and `state` advanced);
    ///   `false` if it was illegal — the guard rejected it and `state` is unchanged.
    @discardableResult
    public mutating func send(_ event: OverlayEvent) -> Bool {
        guard let next = Self.destination(from: state, on: event) else { return false }
        state = next
        return true
    }

    /// Whether `event` would be accepted from the current `state` (no mutation).
    public func canSend(_ event: OverlayEvent) -> Bool {
        Self.destination(from: state, on: event) != nil
    }
}
