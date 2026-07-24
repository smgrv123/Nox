import Foundation

/// Outcome of scanning a single command or script.
///
/// Two-tier model from docs/05-lld.md §11 / PRD §7.3:
/// - `.allow`      — nothing matched; safe to run/insert.
/// - `.confirm`    — a dangerous pattern matched that the user may override via a
///                   distinct, destructive-styled confirmation (Layer 2).
/// - `.hardBlock`  — privilege escalation (`sudo`, `su`, …). No override path in v1.
public enum ScanVerdict: Equatable, Sendable {
    case allow
    case confirm(reason: String, matched: String)
    case hardBlock(reason: String, matched: String)

    /// Convenience for tests / call sites that only care about the tier.
    public var isBlocked: Bool {
        switch self {
        case .allow: return false
        case .confirm, .hardBlock: return true
        }
    }
}
