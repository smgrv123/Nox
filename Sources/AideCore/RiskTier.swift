import Foundation

/// The per-Skill/Automation risk classification declared in every Manifest.
///
/// This is the deterministic input that decides confirmation behaviour — it is
/// *not* derived from any model score. See docs/02-glossary.md ("Risk Tier") and
/// docs/05-lld.md §2.1 / §4.2.
///
/// - `low`:            execute when the Confidence Gate passes; no prompt.
/// - `confirm`:        execute silently when routing confidence is clearly high;
///                     Confirm-Back when it is marginal (the logprob gate decides).
/// - `alwaysConfirm`:  always Confirm-Back, regardless of confidence
///                     (destructive / irreversible actions).
///
/// The raw values match the on-disk Manifest JSON (`low` | `confirm` | `always_confirm`).
public enum RiskTier: String, Codable, Sendable, CaseIterable {
    case low
    case confirm
    case alwaysConfirm = "always_confirm"
}
