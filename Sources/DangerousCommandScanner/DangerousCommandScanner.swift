import Foundation

/// Deterministic, pattern-based guard for generated scripts and one-off commands.
///
/// This is a Swift, in-process scanner that treats input as **data** and never
/// executes it — it cannot be prompt-injected (PRD §7.3, docs/05-lld.md §4.3/§11).
///
/// Scope of THIS file: a faithful first-pass classifier covering the highest-value
/// blocklist entries. It normalises whitespace and inspects the raw string plus its
/// pipe/`;`/`&&` segments.
///
/// TODO (docs/05-lld.md §4.3): full lexical tokenisation with **recursive descent**
/// into `$(...)`, backticks, and `sh -c "…"` / `bash -c "…"` so nested cases such as
/// `bash -c "rm -rf *"` are decomposed and each layer scanned. The default posture is
/// strict: false positives (over-confirming) are acceptable; false negatives are not.
public struct DangerousCommandScanner: Sendable {

    public init() {}

    /// A single blocklist rule.
    private struct Rule {
        let regex: NSRegularExpression
        let reason: String
        let hard: Bool
    }

    /// Ordered rules. Hard-block rules are checked first so privilege escalation
    /// always wins over a co-occurring confirm-tier match.
    private static let rules: [Rule] = {
        func rx(_ pattern: String) -> NSRegularExpression {
            // Patterns are authored case-insensitively; `\b` word boundaries keep
            // us from matching inside larger identifiers (e.g. "pseudocode").
            // The pattern is a compile-time constant literal, so this never throws.
            // swiftlint:disable:next force_try
            try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        }
        return [
            // ---- HARD BLOCK: privilege escalation (no override path, PRD §7.3) ----
            Rule(
                regex: rx(#"(^|[\s;&|(])sudo\b"#),
                reason: "Runs a command as root. Privilege escalation is never permitted.",
                hard: true),
            Rule(
                regex: rx(#"(^|[\s;&|(])su\b"#),
                reason: "Switches to another (super)user. Privilege escalation is never permitted.",
                hard: true),
            Rule(
                regex: rx(#"(^|[\s;&|(])doas\b"#),
                reason: "Privilege escalation via doas is never permitted.",
                hard: true),

            // ---- CONFIRM: destructive / dangerous (override via Layer 2) ----
            // NOTE: recursive `rm` is handled by `recursiveRmMatch(in:)` below, not
            // a regex, so separated flags (`rm -r -f`) can't slip past a single pattern.
            Rule(
                regex: rx(#"\b(srm|shred)\b"#),
                reason: "Securely erases files. This is irreversible.",
                hard: false),
            Rule(
                regex: rx(#"\b(curl|wget)\b[^|]*\|\s*(sudo\s+)?(sh|bash|zsh)\b"#),
                reason: "Pipes a downloaded script straight into a shell (remote code execution).",
                hard: false),
            Rule(
                regex: rx(#"\bdd\b[^\n]*\bof=/dev/"#),
                reason: "Writes raw bytes directly to a device. Can destroy a disk.",
                hard: false),
            Rule(
                regex: rx(#"\bmkfs(\.\w+)?\b"#),
                reason: "Formats a filesystem. Destroys all data on the target.",
                hard: false),
            Rule(
                regex: rx(#"\bdiskutil\s+(erase|reformat|partitionDisk)\w*"#),
                reason: "Erases or reformats a disk. Destroys all data on the target.",
                hard: false),
            Rule(
                regex: rx(#"\bchmod\s+-R\s+0*777\b"#),
                reason: "Recursively makes files world-writable. A security risk.",
                hard: false),
            Rule(
                regex: rx(#"\bkill\s+-9\s+-1\b"#),
                reason: "Sends SIGKILL to every process the user owns.",
                hard: false),
            Rule(
                regex: rx(#":\s*\(\s*\)\s*\{\s*:\s*\|\s*:\s*&\s*\}\s*;\s*:"#),
                reason: "Fork bomb — spawns processes until the machine is unusable.",
                hard: false),
            Rule(
                regex: rx(#"\bcrontab\s+-r\b"#),
                reason: "Deletes all of the user's cron jobs.",
                hard: false),
            Rule(
                regex: rx(#"\b(base64\s+(-D|--decode|-d)[^\n]*\|\s*(sh|bash|zsh)|eval\b)"#),
                reason:
                    "Decodes-then-executes or evaluates a constructed string — a common obfuscation.",
                hard: false),
        ]
    }()

    /// Scan a command / script and return the strictest matching verdict.
    ///
    /// - Parameter command: the raw command or full script text.
    /// - Returns: `.hardBlock` if any privilege-escalation rule matches, else the
    ///   first `.confirm` match, else `.allow`.
    public func scan(_ command: String) -> ScanVerdict {
        let normalized = normalize(command)
        let full = NSRange(normalized.startIndex..., in: normalized)

        // Hard-block rules take precedence over confirm rules.
        for rule in Self.rules where rule.hard {
            if let match = rule.regex.firstMatch(in: normalized, range: full) {
                return .hardBlock(reason: rule.reason, matched: matchedText(match, in: normalized))
            }
        }

        // Recursive `rm` is checked with a flag-aware scan (not a single regex) so
        // that separated flags — `rm -r -f`, `rm --recursive` — cannot slip past.
        if let matched = recursiveRmMatch(in: normalized) {
            return .confirm(
                reason: "Recursively deletes files. This is irreversible.", matched: matched)
        }

        for rule in Self.rules where !rule.hard {
            if let match = rule.regex.firstMatch(in: normalized, range: full) {
                return .confirm(reason: rule.reason, matched: matchedText(match, in: normalized))
            }
        }
        return .allow
    }

    /// Detect a recursive `rm` in any pipeline segment, regardless of how the
    /// recursive flag is spelled: `-rf`, `-r -f`, `-fr`, `-R`, `--recursive`.
    /// Recursive delete is flagged even without `-f` — it is already irreversible.
    private func recursiveRmMatch(in normalized: String) -> String? {
        let separators: Set<Character> = [";", "&", "|", "\n"]
        for segment in normalized.split(whereSeparator: { separators.contains($0) }) {
            let tokens = segment.split(separator: " ").map(String.init)
            guard let cmdIdx = tokens.firstIndex(where: { $0 == "rm" || $0.hasSuffix("/rm") })
            else { continue }
            let args = tokens[tokens.index(after: cmdIdx)...]
            let isRecursive = args.contains { token in
                if token == "--recursive" { return true }
                // A short-flag cluster like "-rf" / "-R" — but not a long flag ("--force").
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

    /// Collapse runs of whitespace so patterns like `rm   -rf` still match, while
    /// preserving segment separators. (A full tokeniser is the LLD §4.3 upgrade.)
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
