import Foundation

/// Pure AX-vs-paste planner (LLD §4.7). Terminal scanning is the driver's job;
/// `isTerminal` is reserved for Phase 2 and ignored here.
public struct InsertionPlanner: Sendable {
    public init() {}

    public func plan(
        focus: InsertionFocus,
        override: AppInsertionOverride?,
        isTerminal: Bool
    ) -> InsertionPlan {
        _ = focus
        _ = isTerminal
        switch override {
        case .paste: return .pasteOnly
        case .ax: return .axOnly
        case nil: return .axThenPaste
        }
    }
}
