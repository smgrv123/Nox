import AideCore
import Foundation

/// Production `InstalledApplicationCatalog`: enumerates the flat app-bundle
/// roots on disk and reads each bundle's real `Info.plist` display name.
struct InstalledApplicationCatalogLive: InstalledApplicationCatalog {

    func installedApplications() async -> [InstalledApplication] {
        Self.roots.flatMap { root in
            Self.applications(inRoot: root.path, isSystemUtility: root.isSystemUtility)
        }
    }

    private static var roots: [(path: String, isSystemUtility: Bool)] {
        [
            ("/Applications", false),
            ("/System/Applications", false),
            ("/System/Applications/Utilities", true),
            (NSHomeDirectory() + "/Applications", false),
        ]
    }

    private static func applications(inRoot root: String, isSystemUtility: Bool)
        -> [InstalledApplication] {
        let rootURL = URL(fileURLWithPath: root)
        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: rootURL, includingPropertiesForKeys: nil)
        else {
            return []
        }
        return
            entries
            .filter { $0.pathExtension == "app" }
            .map { bundleURL in
                InstalledApplication(
                    displayName: displayName(forBundleAt: bundleURL),
                    bundleURL: bundleURL,
                    isSystemUtility: isSystemUtility)
            }
    }

    private static func displayName(forBundleAt bundleURL: URL) -> String {
        let bundle = Bundle(url: bundleURL)
        if let name = bundle?.localizedInfoDictionary?["CFBundleDisplayName"] as? String {
            return name
        }
        if let name = bundle?.infoDictionary?["CFBundleDisplayName"] as? String {
            return name
        }
        if let name = bundle?.localizedInfoDictionary?["CFBundleName"] as? String {
            return name
        }
        if let name = bundle?.infoDictionary?["CFBundleName"] as? String {
            return name
        }
        return bundleURL.deletingPathExtension().lastPathComponent
    }
}
