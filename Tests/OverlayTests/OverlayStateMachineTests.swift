import XCTest

@testable import Overlay

/// The Overlay state machine (docs/04-hld.md §13.1). TDD per specs/P1 §"Testing
/// Decisions": every legal transition and every illegal-transition guard is covered,
/// exercised through the public interface with no UI or I/O involved.
final class OverlayStateMachineTests: XCTestCase {

    /// The single source of truth for this suite: the exact legal edge set from the
    /// HLD diagram, plus the Push-to-Talk restart edge (`processing --activate-->
    /// listening`, LLD §10). Every other `(state, event)` pair MUST be rejected.
    private static let legalTransitions: [Transition] = [
        Transition(.hidden, .activate, .listening),
        Transition(.listening, .beginProcessing, .processing),
        Transition(.processing, .presentResult, .showingResult),
        Transition(.processing, .presentPromptBack, .promptBack),
        Transition(.processing, .presentConfirmBack, .confirmBack),
        Transition(.processing, .activate, .listening),
        Transition(.showingResult, .dismiss, .hidden),
        Transition(.promptBack, .dismiss, .hidden),
        Transition(.confirmBack, .approve, .showingResult),
        Transition(.confirmBack, .reject, .hidden),
    ]

    private struct Transition {
        let from: OverlayState
        let event: OverlayEvent
        let to: OverlayState
        init(_ from: OverlayState, _ event: OverlayEvent, _ to: OverlayState) {
            self.from = from
            self.event = event
            self.to = to
        }
    }

    // MARK: - Initial state

    func testDefaultInitialStateIsHidden() {
        XCTAssertEqual(OverlayStateMachine().state, .hidden)
        XCTAssertEqual(OverlayState.initial, .hidden)
    }

    func testHiddenIsTheOnlyInvisibleState() {
        for state in OverlayState.allCases {
            XCTAssertEqual(state.isVisible, state != .hidden, "isVisible wrong for \(state)")
        }
    }

    // MARK: - Every legal transition advances correctly

    func testEveryLegalTransitionAdvancesToItsDocumentedState() {
        for transition in Self.legalTransitions {
            // Pure table.
            XCTAssertEqual(
                OverlayStateMachine.destination(from: transition.from, on: transition.event),
                transition.to,
                "destination(\(transition.from), \(transition.event)) should be \(transition.to)")

            // Applied via send: advances and reports success.
            var machine = OverlayStateMachine(state: transition.from)
            XCTAssertTrue(machine.canSend(transition.event))
            XCTAssertTrue(machine.send(transition.event), "\(transition.event) from \(transition.from) should apply")
            XCTAssertEqual(machine.state, transition.to)
        }
    }

    // MARK: - Every illegal transition is guarded (rejected, state unchanged)

    func testEveryIllegalTransitionIsRejectedAndLeavesStateUnchanged() {
        let legal = Set(Self.legalTransitions.map { Pair($0.from, $0.event) })

        for state in OverlayState.allCases {
            for event in OverlayEvent.allCases where !legal.contains(Pair(state, event)) {
                // Pure table returns nil for the guarded pair.
                XCTAssertNil(
                    OverlayStateMachine.destination(from: state, on: event),
                    "\(event) from \(state) must be illegal")

                // send rejects it and does not mutate state.
                var machine = OverlayStateMachine(state: state)
                XCTAssertFalse(machine.canSend(event))
                XCTAssertFalse(machine.send(event), "\(event) from \(state) must be rejected")
                XCTAssertEqual(machine.state, state, "rejected \(event) must leave \(state) unchanged")
            }
        }
    }

    /// Guards its own arithmetic: 6 states × 8 events = 48 pairs, of which exactly 10
    /// are legal — so 38 must be rejected. A drift in either enum trips this.
    func testTransitionCensusMatchesTheDocumentedTable() {
        let total = OverlayState.allCases.count * OverlayEvent.allCases.count
        XCTAssertEqual(total, 48)
        XCTAssertEqual(Self.legalTransitions.count, 10)

        var legalCount = 0
        for state in OverlayState.allCases {
            for event in OverlayEvent.allCases where OverlayStateMachine.destination(from: state, on: event) != nil {
                legalCount += 1
            }
        }
        XCTAssertEqual(legalCount, 10, "exactly 10 of the 48 pairs may be legal")
    }

    // MARK: - Named behaviours called out by the PRD

    /// PRD §"Testing Decisions": "a new activation while `Processing` cancels and restarts."
    func testNewActivationWhileProcessingCancelsAndRestartsListening() {
        var machine = OverlayStateMachine(state: .processing)
        XCTAssertTrue(machine.send(.activate))
        XCTAssertEqual(machine.state, .listening, "a fresh PTT press mid-processing restarts listening")
    }

    /// PRD §"Testing Decisions": "`ConfirmBack` → approved vs rejected outcomes."
    func testConfirmBackApprovedGoesToShowingResult() {
        var machine = OverlayStateMachine(state: .confirmBack)
        XCTAssertTrue(machine.send(.approve))
        XCTAssertEqual(machine.state, .showingResult)
    }

    func testConfirmBackRejectedGoesToHidden() {
        var machine = OverlayStateMachine(state: .confirmBack)
        XCTAssertTrue(machine.send(.reject))
        XCTAssertEqual(machine.state, .hidden)
    }

    // MARK: - End-to-end walks through the graph

    func testHappyPathResultWalk() {
        var machine = OverlayStateMachine()
        XCTAssertTrue(machine.send(.activate))
        XCTAssertEqual(machine.state, .listening)
        XCTAssertTrue(machine.send(.beginProcessing))
        XCTAssertEqual(machine.state, .processing)
        XCTAssertTrue(machine.send(.presentResult))
        XCTAssertEqual(machine.state, .showingResult)
        XCTAssertTrue(machine.send(.dismiss))
        XCTAssertEqual(machine.state, .hidden)
    }

    func testConfirmBackApprovedWalk() {
        var machine = OverlayStateMachine()
        machine.send(.activate)
        machine.send(.beginProcessing)
        XCTAssertTrue(machine.send(.presentConfirmBack))
        XCTAssertEqual(machine.state, .confirmBack)
        XCTAssertTrue(machine.send(.approve))
        XCTAssertEqual(machine.state, .showingResult)
        XCTAssertTrue(machine.send(.dismiss))
        XCTAssertEqual(machine.state, .hidden)
    }

    func testPromptBackWalkReturnsToHidden() {
        var machine = OverlayStateMachine()
        machine.send(.activate)
        machine.send(.beginProcessing)
        XCTAssertTrue(machine.send(.presentPromptBack))
        XCTAssertEqual(machine.state, .promptBack)
        XCTAssertTrue(machine.send(.dismiss))
        XCTAssertEqual(machine.state, .hidden)
    }

    // MARK: - A rejected event never derails a subsequent legal one

    func testRejectedEventDoesNotBlockLaterLegalTransition() {
        var machine = OverlayStateMachine()
        // `dismiss` is illegal from hidden — must be a no-op…
        XCTAssertFalse(machine.send(.dismiss))
        XCTAssertEqual(machine.state, .hidden)
        // …and the machine still accepts the legal `activate` right after.
        XCTAssertTrue(machine.send(.activate))
        XCTAssertEqual(machine.state, .listening)
    }

    // MARK: - Helper

    private struct Pair: Hashable {
        let state: OverlayState
        let event: OverlayEvent
        init(_ state: OverlayState, _ event: OverlayEvent) {
            self.state = state
            self.event = event
        }
    }
}
