import Foundation

/// The Confidence Gate's decision (docs/05-lld.md §3.1 / §4.2). Scanner
/// Hard-Block is **not** a gate outcome — that lives on the Phase 5 Dispatcher.
public enum GateDecision: Equatable, Sendable {
    /// Schema valid, skill resolved, and Risk Tier × `L_mean` allows silent run.
    case execute
    /// Action was resolved but needs an explicit user confirm (`confirm` marginal
    /// or `always_confirm`).
    case confirmBack(prompt: String)
    /// Nothing safe to run: `skill_id == null`, schema hard-reject, or `L_mean`
    /// below `routeLow`. Suggestion is a stable prompt-back string.
    case promptBack(suggestion: String?)
}
