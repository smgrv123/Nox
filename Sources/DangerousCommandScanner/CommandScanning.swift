/// Seam for dependency injection and testing (LLD §3.6).
///
/// Consumers (P4 Dispatcher, P5 Dictation, P7 Automations) depend on this
/// protocol — never the concrete `DangerousCommandScanner` struct — so tests
/// can substitute a stub or mock without touching real rule evaluation.
public protocol CommandScanning: Sendable {
    func scan(_ command: String, context: ScanContext) -> ScanVerdict
}

extension CommandScanning {
    /// Convenience overload: scans with safe one-off defaults.
    public func scan(_ command: String) -> ScanVerdict {
        scan(command, context: ScanContext(channel: .typedOneOff))
    }
}
