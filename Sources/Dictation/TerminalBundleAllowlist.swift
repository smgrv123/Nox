import DangerousCommandScanner

/// Thin wrapper over the scanner's terminal-destination allowlist. Do not
/// duplicate IDs here — `contains` and `ids` both delegate to
/// `TerminalBundleIDs.allowlist`.
public enum TerminalBundleAllowlist {
    public static var ids: Set<String> { TerminalBundleIDs.allowlist }

    public static func contains(_ bundleID: String) -> Bool {
        TerminalBundleIDs.allowlist.contains(bundleID)
    }
}
