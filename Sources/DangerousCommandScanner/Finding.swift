/// A single match produced by the scanner's rule engine (LLD §3.6).
public struct Finding: Equatable, Sendable {
    public let rule: RuleID
    public let severity: Severity
    public let matchedText: String
    public let explanation: String
    /// Nesting trail from root to the matched node, e.g. `["pipe", "sh -c", "rm -rf"]`.
    public let path: [String]

    public init(
        rule: RuleID,
        severity: Severity,
        matchedText: String,
        explanation: String,
        path: [String] = []
    ) {
        self.rule = rule
        self.severity = severity
        self.matchedText = matchedText
        self.explanation = explanation
        self.path = path
    }
}
