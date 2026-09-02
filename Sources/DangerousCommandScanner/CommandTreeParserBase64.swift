import Foundation

/// Detects `base64 --decode | sh` obfuscation patterns across pipe-connected
/// segments. Produces a `.obfuscatedExecution` finding when matched; attempts
/// one static-literal decode pass when the encoded payload is visible.
extension CommandTreeParser {

    private static let shellNames: Set<String> = ["sh", "bash", "zsh"]
    private static let decodeFlags: Set<String> = ["-d", "-D", "--decode"]

    static func detectBase64PipeShell(
        in segments: [Segment],
        findings: inout [Finding]
    ) {
        guard segments.count >= 2 else { return }
        for idx in 0..<(segments.count - 1) {
            guard segments[idx + 1].precedingOperator == .pipe else { continue }
            let leftArgv = extractArgv(from: segments[idx].tokens)
            let rightArgv = extractArgv(from: segments[idx + 1].tokens)
            guard isBase64Decode(leftArgv), isShell(rightArgv) else { continue }

            let shellName = rightArgv[0]
            findings.append(
                Finding(
                    rule: .obfuscatedExecution,
                    severity: .confirm,
                    matchedText: "base64 decode | \(shellName)",
                    explanation:
                        "Decodes data then pipes into a shell — a common obfuscation technique.",
                    path: ["pipe"]
                ))

            tryStaticDecode(
                segments: segments, base64Idx: idx, findings: &findings)
        }
    }

    // MARK: - Helpers

    private static func extractArgv(from tokens: [ShellToken]) -> [String] {
        tokens.compactMap {
            if case .word(let text) = $0 { return text }
            return nil
        }
    }

    private static func isBase64Decode(_ argv: [String]) -> Bool {
        argv.first == "base64" && argv.dropFirst().contains(where: { decodeFlags.contains($0) })
    }

    private static func isShell(_ argv: [String]) -> Bool {
        guard let cmd = argv.first else { return false }
        return shellNames.contains(cmd)
    }

    /// Best-effort: if the segment before `base64 -d` is `echo "literal"`,
    /// decode the literal and scan the result as a child tree.
    private static func tryStaticDecode(
        segments: [Segment],
        base64Idx: Int,
        findings: inout [Finding]
    ) {
        guard base64Idx > 0,
            segments[base64Idx].precedingOperator == .pipe
        else { return }
        let feederArgv = extractArgv(from: segments[base64Idx - 1].tokens)
        guard feederArgv.first == "echo", feederArgv.count >= 2 else { return }
        let literal = feederArgv.dropFirst().joined(separator: " ")
        guard let data = Data(base64Encoded: literal),
            let decoded = String(data: data, encoding: .utf8)
        else { return }

        let innerNodes = parseString(
            decoded, path: ["base64 -d"], depth: 1, findings: &findings)
        _ = innerNodes
    }
}
