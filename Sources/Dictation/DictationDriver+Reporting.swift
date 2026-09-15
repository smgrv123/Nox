import AideCore

extension DictationDriver {

    static func resultSummary(
        insertion: InsertionResult,
        cleanupOutcome: DictationCleanupOutcome,
        accessibilityTrusted: Bool
    ) -> String {
        switch insertion {
        case .copiedToClipboard:
            return copiedToClipboardSummary
        case .failed(let failure):
            // `TextInserterLive` reports Secure Input distinctly when it detects
            // `IsSecureEventInputEnabled()` before ever posting ⌘V — surface that
            // distinctly, since "copied to clipboard instead" reads as a generic
            // paste failure and gives the user no way to tell a manual paste (which
            // works fine under Secure Input) is the fix.
            switch failure {
            case .secureInput:
                return secureInputSummary
            case .pasteFailed:
                return copiedToClipboardSummary
            }
        case .insertedViaPaste:
            switch cleanupOutcome {
            case .sidecarNotReady, .chatFailed:
                // Cleanup itself is why we're inserting raw text — that story trumps
                // the accessibility-denied copy even when AX is also untrusted.
                return cleanupOutcome.overlayCopy
            case .cleaned, .skipped:
                if !accessibilityTrusted {
                    return accessibilityDeniedSummary
                }
                return cleanupOutcome.overlayCopy
            }
        }
    }

    /// Elapsed time since `start`, in whole milliseconds (P5a latency instrumentation).
    /// `ContinuousClock`-measured — monotonic, immune to wall-clock adjustment.
    static func elapsedMs(since start: ContinuousClock.Instant) -> Int {
        let duration = ContinuousClock.now - start
        let (seconds, attoseconds) = duration.components
        return Int((Double(seconds) * 1000) + (Double(attoseconds) / 1e15))
    }

    static func historyInsertion(_ result: InsertionResult) -> InsertionKind {
        switch result {
        case .insertedViaPaste: return .paste
        case .copiedToClipboard: return .copied
        case .failed: return .failed
        }
    }

}
