import Foundation

/// Deterministic, pattern-based guard for generated scripts and one-off commands.
///
/// This is a Swift, in-process scanner that treats input as **data** and never
/// executes it — it cannot be prompt-injected (PRD §7.3, docs/05-lld.md §4.3/§11).
///
/// **Current implementation:** regex-based first-pass classifier covering the
/// highest-value blocklist entries. The structured rule engine (LLD §4.3 Phase C)
/// replaces these regexes in Phase 3; this bridge wraps regex matches into `Finding`
/// objects under the new `ScanVerdict` shape.
public struct DangerousCommandScanner: Sendable {

    public init() {}

    private struct Rule {
        let regex: NSRegularExpression
        let reason: String
        let hard: Bool
        let ruleID: RuleID
    }

    private static let rules: [Rule] = {
        func rx(_ pattern: String) -> NSRegularExpression {
            // swiftlint:disable:next force_try
            try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        }
        return [
            Rule(
                regex: rx(#"(^|[\s;&|(])sudo\b"#),
                reason: "Runs a command as root. Privilege escalation is never permitted.",
                hard: true,
                ruleID: .privilegeEscalation),
            Rule(
                regex: rx(#"(^|[\s;&|(])su\b"#),
                reason: "Switches to another (super)user. Privilege escalation is never permitted.",
                hard: true,
                ruleID: .privilegeEscalation),
            Rule(
                regex: rx(#"(^|[\s;&|(])doas\b"#),
                reason: "Privilege escalation via doas is never permitted.",
                hard: true,
                ruleID: .privilegeEscalation),
            Rule(
                regex: rx(#"\b(srm|shred)\b"#),
                reason: "Securely erases files. This is irreversible.",
                hard: false,
                ruleID: .secureErase),
            Rule(
                regex: rx(#"\b(curl|wget)\b[^|]*\|\s*(sudo\s+)?(sh|bash|zsh)\b"#),
                reason: "Pipes a downloaded script straight into a shell (remote code execution).",
                hard: false,
                ruleID: .pipedRemoteExecution),
            Rule(
                regex: rx(#"\bdd\b[^\n]*\bof=/dev/"#),
                reason: "Writes raw bytes directly to a device. Can destroy a disk.",
                hard: true,
                ruleID: .diskDestruction),
            Rule(
                regex: rx(#"\bmkfs(\.\w+)?\b"#),
                reason: "Formats a filesystem. Destroys all data on the target.",
                hard: true,
                ruleID: .diskDestruction),
            Rule(
                regex: rx(#"\bdiskutil\s+(erase|reformat|partitionDisk)\w*"#),
                reason: "Erases or reformats a disk. Destroys all data on the target.",
                hard: true,
                ruleID: .diskDestruction),
            Rule(
                regex: rx(#"\bchmod\s+-R\s+0*777\b"#),
                reason: "Recursively makes files world-writable. A security risk.",
                hard: false,
                ruleID: .broadPermissionChange),
            Rule(
                regex: rx(#"\bkill\s+-9\s+-1\b"#),
                reason: "Sends SIGKILL to every process the user owns.",
                hard: false,
                ruleID: .broadKill),
            Rule(
                regex: rx(#":\s*\(\s*\)\s*\{\s*:\s*\|\s*:\s*&\s*\}\s*;\s*:"#),
                reason: "Fork bomb — spawns processes until the machine is unusable.",
                hard: true,
                ruleID: .forkBomb),
            Rule(
                regex: rx(#"\bcrontab\s+-r\b"#),
                reason: "Deletes all of the user's cron jobs.",
                hard: false,
                ruleID: .shellProfileEdit),
            Rule(
                regex: rx(#"\b(base64\s+(-D|--decode|-d)[^\n]*\|\s*(sh|bash|zsh)|eval\b)"#),
                reason:
                    "Decodes-then-executes or evaluates a constructed string — a common obfuscation.",
                hard: false,
                ruleID: .obfuscatedExecution),
        ]
    }()

    /// Scan a shell command string for dangerous patterns.
    ///
    /// - Parameter context: Phase 1 bridge — accepted but not yet consumed.
    ///   Context-dependent behavior (H7 escalation for Aide-generated automations,
    ///   C11 terminal-dictation detection) arrives with the structured rule engine
    ///   in Phase 3.
    public func scan(_ command: String, context: ScanContext = .init()) -> ScanVerdict {
        let normalized = normalize(command)
        let full = NSRange(normalized.startIndex..., in: normalized)

        // Hard-block rules are checked first so privilege escalation / disk destruction
        // always wins over a co-occurring confirm match.
        for rule in Self.rules where rule.hard {
            if let match = rule.regex.firstMatch(in: normalized, range: full) {
                return .hardBlock(findings: [makeFinding(rule, match, normalized, .hardBlock)])
            }
        }

        // Flag-aware scanning (not regex) so separated flags like `rm -r -f` can't
        // slip past a naive single-token pattern.
        if let matched = recursiveRmMatch(in: normalized) {
            let finding = Finding(
                rule: .recursiveDelete,
                severity: .confirm,
                matchedText: matched,
                explanation: "Recursively deletes files. This is irreversible."
            )
            return .confirm(findings: [finding])
        }

        for rule in Self.rules where !rule.hard {
            if let match = rule.regex.firstMatch(in: normalized, range: full) {
                return .confirm(findings: [makeFinding(rule, match, normalized, .confirm)])
            }
        }
        return .clean
    }

    private func makeFinding(
        _ rule: Rule, _ match: NSTextCheckingResult, _ text: String, _ severity: Severity
    ) -> Finding {
        Finding(
            rule: rule.ruleID,
            severity: severity,
            matchedText: matchedText(match, in: text),
            explanation: rule.reason
        )
    }

    private func recursiveRmMatch(in normalized: String) -> String? {
        let separators: Set<Character> = [";", "&", "|", "\n"]
        for segment in normalized.split(whereSeparator: { separators.contains($0) }) {
            let tokens = segment.split(separator: " ").map(String.init)
            guard let cmdIdx = tokens.firstIndex(where: { $0 == "rm" || $0.hasSuffix("/rm") })
            else { continue }
            let args = tokens[tokens.index(after: cmdIdx)...]
            let isRecursive = args.contains { token in
                if token == "--recursive" { return true }
                guard token.hasPrefix("-"), !token.hasPrefix("--") else { return false }
                return token.dropFirst().contains { $0 == "r" || $0 == "R" }
            }
            if isRecursive {
                return (["rm"] + args).joined(separator: " ")
            }
        }
        return nil
    }

    // MARK: - Helpers

    // Collapse whitespace so patterns like `rm   -rf` still match the regex rules,
    // while preserving segment separators (newlines) for per-command splitting.
    private func normalize(_ input: String) -> String {
        input
            .replacingOccurrences(of: "\t", with: " ")
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map { line in
                line.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
            }
            .joined(separator: "\n")
    }

    private func matchedText(_ match: NSTextCheckingResult, in string: String) -> String {
        guard let range = Range(match.range, in: string) else { return "" }
        return String(string[range]).trimmingCharacters(in: .whitespaces)
    }
}
