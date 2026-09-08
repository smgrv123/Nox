import Foundation

/// AX-first vs paste-fallback decision inputs. The live shell holds `AXUIElement`
/// values; this module never imports ApplicationServices (LLD §3.5 deviation).
public struct InsertionFocus: Equatable, Sendable {
    public var bundleID: String?
    public var accessibilityTrusted: Bool

    public init(bundleID: String?, accessibilityTrusted: Bool) {
        self.bundleID = bundleID
        self.accessibilityTrusted = accessibilityTrusted
    }
}

/// Per-app insertion override persisted in `settings.text_insertion.app_overrides`.
public enum AppInsertionOverride: String, Equatable, Sendable, Codable {
    case ax
    case paste
}

/// How the live inserter should attempt to place text (LLD §4.7).
public enum InsertionPlan: Equatable, Sendable {
    case axThenPaste
    case axOnly
    case pasteOnly
}

/// Outcome of one insertion attempt (LLD §3.5).
public enum InsertionResult: Equatable, Sendable {
    case insertedViaAX
    case insertedViaPaste
    case failed(reason: String)
    case copiedToClipboard
}

/// Effectful text insertion at the caret. Production: `App/TextInserterLive.swift`.
@MainActor
public protocol TextInserting: AnyObject {
    func resolveFocus() async -> InsertionFocus
    func insert(_ text: String, plan: InsertionPlan) async -> InsertionResult
    func copyToClipboard(_ text: String) async
}

extension TextInserting {
    public func copyToClipboard(_ text: String) async {}
}
