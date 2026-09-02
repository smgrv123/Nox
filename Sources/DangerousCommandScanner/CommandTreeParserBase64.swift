import Foundation

/// Detects obfuscation-to-shell patterns across pipe-connected segments:
/// `base64 -d | sh`, `openssl enc -d | sh`, `xxd -r | sh`, `printf … | sh`.
/// Produces `.obfuscatedExecution` findings; attempts one static-literal decode
/// pass for base64 when the encoded payload is visible.
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
            guard isShell(rightArgv) else { continue }

            if let label = obfuscationLabel(leftArgv) {
                let shellName = rightArgv[0]
                findings.append(
                    Finding(
                        rule: .obfuscatedExecution,
                        severity: .confirm,
                        matchedText: "\(label) | \(shellName)",
                        explanation:
                            "Decodes/generates data then pipes into a shell — obfuscation technique.",
                        path: ["pipe"]
                    ))

                if isBase64Decode(leftArgv) {
                    tryStaticDecode(
                        segments: segments, base64Idx: idx, findings: &findings)
                }
            }
        }
    }

    // MARK: - Obfuscation matchers

    private static func obfuscationLabel(_ argv: [String]) -> String? {
        if isBase64Decode(argv) { return "base64 decode" }
        if isOpensslDecode(argv) { return "openssl decode" }
        if isXxdReverse(argv) { return "xxd reverse" }
        if isPrintfHex(argv) { return "printf hex" }
        return nil
    }

    private static func isBase64Decode(_ argv: [String]) -> Bool {
        guard argv.first == "base64" else { return false }
        return argv.dropFirst().contains { decodeFlags.contains($0) }
    }

    private static func isOpensslDecode(_ argv: [String]) -> Bool {
        guard argv.first == "openssl" else { return false }
        let rest = Array(argv.dropFirst())
        let hasEnc = rest.contains("enc")
        let hasDec = rest.contains("-d") || rest.contains("--decrypt")
        return hasEnc && hasDec
    }

    private static func isXxdReverse(_ argv: [String]) -> Bool {
        guard argv.first == "xxd" else { return false }
        return argv.dropFirst().contains("-r")
    }

    private static func isPrintfHex(_ argv: [String]) -> Bool {
        guard argv.first == "printf" else { return false }
        let args = argv.dropFirst().joined(separator: " ")
        return args.contains("\\x")
    }

    // MARK: - Helpers

    static func extractArgv(from tokens: [ShellToken]) -> [String] {
        tokens.compactMap {
            if case .word(let text) = $0 { return text }
            return nil
        }
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
