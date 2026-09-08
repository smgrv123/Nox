import Foundation

/// One installed macOS application, as discovered on disk.
///
/// `displayName` is the app's real, user-facing name (read from its bundle's
/// `Info.plist`), not a filename guess — this is what lets skill dispatch match
/// spoken app names ("vscode") against what's actually installed
/// ("Visual Studio Code") rather than only an exact `<name>.app` filename.
public struct InstalledApplication: Sendable, Equatable {
    public let displayName: String
    public let bundleURL: URL
    /// `true` only for entries discovered under `/System/Applications/Utilities`,
    /// so callers can filter out Utilities clutter without a second enumeration.
    public let isSystemUtility: Bool

    public init(displayName: String, bundleURL: URL, isSystemUtility: Bool = false) {
        self.displayName = displayName
        self.bundleURL = bundleURL
        self.isSystemUtility = isSystemUtility
    }
}

/// Enumerates the applications actually installed on this Mac. The App layer
/// injects a real conformer (`FileManager` + bundle `Info.plist` reads); tests
/// inject a mock with a fixed list.
public protocol InstalledApplicationCatalog: Sendable {
    func installedApplications() async -> [InstalledApplication]
}

extension InstalledApplicationCatalog {
    public func installedApplicationNames() async -> [String] {
        await installedApplications().map(\.displayName)
    }
}
