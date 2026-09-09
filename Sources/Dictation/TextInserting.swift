import Foundation

/// Insertion-focus inputs. The live shell holds `AXUIElement` values; this module
/// never imports ApplicationServices (LLD §3.5 deviation). `accessibilityTrusted`
/// still gates insertion — posting synthetic ⌘V requires Accessibility permission
/// exactly as the removed AX write did.
public struct InsertionFocus: Equatable, Sendable {
    public var bundleID: String?
    public var accessibilityTrusted: Bool

    public init(bundleID: String?, accessibilityTrusted: Bool) {
        self.bundleID = bundleID
        self.accessibilityTrusted = accessibilityTrusted
    }
}

/// Why `TextInserting.insert(_:)` failed (LLD §3.5). Typed so callers can switch
/// exhaustively on the *reason* rather than substring-matching a free-text message —
/// a previous `reason.contains("Secure Input")` check in `DictationDriver.resultSummary`
/// would silently stop matching (no compile error, no test failure) if `TextInserterLive`
/// ever reworded its failure string.
public enum InsertionFailure: Equatable, Sendable {
    /// macOS Secure Input was active (any password field focused anywhere on the
    /// system), so the synthetic ⌘V would have been silently discarded — detected in
    /// advance via `IsSecureEventInputEnabled()`, before ever touching the clipboard.
    case secureInput
    /// Paste was attempted but didn't land (e.g. `CGEvent` construction/posting
    /// failed). `detail` keeps the human-readable reason for logs/debugging.
    case pasteFailed(detail: String)
}

/// Outcome of one insertion attempt (LLD §3.5).
public enum InsertionResult: Equatable, Sendable {
    case insertedViaPaste
    case failed(InsertionFailure)
    case copiedToClipboard
}

/// Effectful text insertion at the caret. Production: `App/TextInserterLive.swift`.
/// Paste-only (LLD §4.7 deviation): `AXUIElementSetAttributeValue` returns
/// `.success` on acceptance, not on actually placing text — Electron/Catalyst/custom
/// text views accept and discard it, so AX insertion is no longer attempted.
@MainActor
public protocol TextInserting: AnyObject {
    func resolveFocus() async -> InsertionFocus
    func insert(_ text: String) async -> InsertionResult
    func copyToClipboard(_ text: String) async
}
