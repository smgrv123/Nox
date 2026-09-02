/// Recursive-descent parser that transforms a `[ShellToken]` stream into a
/// `CommandNode` tree (LLD §4.3 Phase B). Splits on pipeline operators,
/// recurses into substitutions and wrapper commands (sh -c, eval, xargs, …),
/// and enforces a depth limit.
public enum CommandTreeParser: Sendable {

    public static let maxDepth = 8

    public struct ParseResult: Equatable, Sendable {
        public let nodes: [CommandNode]
        public let findings: [Finding]

        /// Every node in the tree, depth-first — convenient for rule evaluation.
        public var allNodes: [CommandNode] {
            nodes.flatMap(\.flattened)
        }
    }

    struct Segment {
        let tokens: [ShellToken]
        let precedingOperator: ShellToken.Operator?
    }

    // MARK: - Entry point

    public static func parse(_ tokens: [ShellToken]) -> ParseResult {
        var findings: [Finding] = []
        let segments = splitOnOperators(tokens)
        var nodes: [CommandNode] = []

        for segment in segments {
            let basePath: [String] = segment.precedingOperator == .pipe ? ["pipe"] : []
            guard !segment.tokens.isEmpty else { continue }
            if let node = parseSegment(
                segment.tokens, path: basePath, depth: 0, findings: &findings
            ) {
                nodes.append(node)
            }
        }

        detectBase64PipeShell(in: segments, findings: &findings)
        return ParseResult(nodes: nodes, findings: findings)
    }

    // MARK: - Segment splitting

    static func splitOnOperators(_ tokens: [ShellToken]) -> [Segment] {
        var segments: [Segment] = []
        var current: [ShellToken] = []
        var precedingOp: ShellToken.Operator?

        for token in tokens {
            if case .operator(let op) = token, isSeparator(op) {
                segments.append(Segment(tokens: current, precedingOperator: precedingOp))
                current = []
                precedingOp = op
            } else {
                current.append(token)
            }
        }
        segments.append(Segment(tokens: current, precedingOperator: precedingOp))
        return segments
    }

    private static func isSeparator(_ op: ShellToken.Operator) -> Bool {
        switch op {
        case .pipe, .or, .and, .semi, .newline, .background: return true
        default: return false
        }
    }

    // MARK: - Recursive helpers

    static func parseInner(
        _ tokens: [ShellToken],
        path: [String],
        depth: Int,
        findings: inout [Finding]
    ) -> [CommandNode] {
        if depth > maxDepth {
            findings.append(depthLimitFinding(path: path))
            return []
        }
        let segments = splitOnOperators(tokens)
        var nodes: [CommandNode] = []
        for segment in segments {
            let segPath = segment.precedingOperator == .pipe ? path + ["pipe"] : path
            guard !segment.tokens.isEmpty else { continue }
            if let node = parseSegment(
                segment.tokens, path: segPath, depth: depth, findings: &findings
            ) {
                nodes.append(node)
            }
        }
        return nodes
    }

    static func parseString(
        _ string: String,
        path: [String],
        depth: Int,
        findings: inout [Finding]
    ) -> [CommandNode] {
        parseInner(ShellTokenizer.tokenize(string), path: path, depth: depth, findings: &findings)
    }

    static func parseArgvAsCommand(
        _ argv: [String],
        path: [String],
        depth: Int,
        findings: inout [Finding]
    ) -> [CommandNode] {
        if depth > maxDepth {
            findings.append(depthLimitFinding(path: path))
            return []
        }
        let tokens = argv.map { ShellToken.word($0) }
        if let node = parseSegment(tokens, path: path, depth: depth, findings: &findings) {
            return [node]
        }
        return []
    }

    static func depthLimitFinding(path: [String]) -> Finding {
        Finding(
            rule: .unparseable,
            severity: .confirm,
            matchedText: path.joined(separator: " → "),
            explanation: "Command nesting exceeds the safety depth limit.",
            path: path
        )
    }
}
