/// Segment-level parsing: extracts argv and child nodes from a single segment's
/// token stream.
extension CommandTreeParser {

    static func parseSegment(
        _ tokens: [ShellToken],
        path: [String],
        depth: Int,
        findings: inout [Finding]
    ) -> CommandNode? {
        var state = SegmentState()

        for token in tokens {
            if state.skipNext {
                state.skipNext = false
                continue
            }
            processToken(token, state: &state, path: path, depth: depth, findings: &findings)
        }

        guard !state.argv.isEmpty else {
            return state.children.isEmpty
                ? nil
                : CommandNode(argv: [], path: path, children: state.children)
        }

        let wrapperChildren = detectWrappers(
            argv: state.argv, path: path, depth: depth, findings: &findings
        )
        state.children.append(contentsOf: wrapperChildren)

        return CommandNode(argv: state.argv, path: path, children: state.children)
    }

    private struct SegmentState {
        var argv: [String] = []
        var children: [CommandNode] = []
        var skipNext = false
    }

    private static func processToken(
        _ token: ShellToken,
        state: inout SegmentState,
        path: [String],
        depth: Int,
        findings: inout [Finding]
    ) {
        switch token {
        case .word(let text):
            state.argv.append(text)

        case .substitution(let kind, let innerTokens):
            let label = kind == .dollarParen ? "$()" : "`...`"
            let sub = parseInner(
                innerTokens, path: path + [label], depth: depth + 1, findings: &findings
            )
            state.children.append(contentsOf: sub)

        case .operator(let op) where isRedirect(op):
            state.skipNext = true

        case .operator, .opaque:
            break
        }
    }

    private static func isRedirect(_ op: ShellToken.Operator) -> Bool {
        switch op {
        case .redirectIn, .redirectOut, .redirectAppend: return true
        default: return false
        }
    }
}
