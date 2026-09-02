/// Deterministic, structural guard for generated scripts and one-off commands.
///
/// This is a Swift, in-process scanner that treats input as **data** and never
/// executes it — it cannot be prompt-injected (PRD §7.3, docs/05-lld.md §4.3/§11).
///
/// **Pipeline:** tokenize (Phase 1) → parse into tree (Phase 2) → evaluate
/// structural rules + combine verdict (Phase 3).
public struct DangerousCommandScanner: Sendable {

    public init() {}

    /// Scan a shell command string for dangerous patterns.
    ///
    /// 1. Tokenizes the raw input via `ShellTokenizer`.
    /// 2. Parses into a `CommandNode` tree via `CommandTreeParser`.
    /// 3. Walks every node, evaluating structural rules (H1–H7, C1–C12).
    /// 4. Combines findings into a verdict: hardBlock > confirm > clean.
    public func scan(_ command: String, context: ScanContext = .init()) -> ScanVerdict {
        let tokens = ShellTokenizer.tokenize(command)
        let parseResult = CommandTreeParser.parse(tokens)
        return ScanRuleEngine.evaluate(
            parseResult: parseResult,
            rawInput: command,
            context: context)
    }
}
