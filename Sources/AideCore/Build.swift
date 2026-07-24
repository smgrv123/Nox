import Foundation

/// Build-wide constants shared across modules and the app target.
public enum Build {
    /// Marketing version. Keep in sync with `MARKETING_VERSION` in project.yml.
    public static let version = "0.1.0"

    /// Reverse-DNS identifier used as the logging subsystem and bundle-id prefix.
    public static let bundleIdentifier = "com.aide.Aide"
}
