import Foundation

// MARK: - C7: Path restriction — per-node checks (LLD §11.3)

extension ScanRules {

    private static let pathSensitiveDeleteCmds: Set<String> = ["rm"]
    private static let pathSensitiveMoveCmds: Set<String> = ["mv"]
    private static let pathSensitiveCopyCmds: Set<String> = ["cp"]

    static func c7PathRestriction(_ node: CommandNode) -> Finding? {
        guard let cmd = node.argv.first else { return nil }
        let targets = targetPaths(cmd: cmd, argv: node.argv)
        for target in targets {
            if let finding = PathRestriction.checkTarget(target, node: node) {
                return finding
            }
        }
        return nil
    }

    private static func targetPaths(
        cmd: String, argv: [String]
    ) -> [String] {
        if pathSensitiveDeleteCmds.contains(cmd) {
            return rmTargets(argv)
        }
        if pathSensitiveMoveCmds.contains(cmd) {
            return mvTargets(argv)
        }
        if pathSensitiveCopyCmds.contains(cmd) {
            return cpTargets(argv)
        }
        if cmd == "dd" { return ddTargets(argv) }
        return []
    }

    private static func rmTargets(_ argv: [String]) -> [String] {
        argv.dropFirst().filter { !$0.hasPrefix("-") }
    }

    private static func mvTargets(_ argv: [String]) -> [String] {
        argv.dropFirst().filter { !$0.hasPrefix("-") }
    }

    private static func cpTargets(_ argv: [String]) -> [String] {
        let nonFlags = argv.dropFirst().filter { !$0.hasPrefix("-") }
        guard let last = nonFlags.last else { return [] }
        return [last]
    }

    private static func ddTargets(_ argv: [String]) -> [String] {
        argv.compactMap { arg -> String? in
            guard arg.hasPrefix("of=") else { return nil }
            return String(arg.dropFirst(3))
        }
    }
}

// MARK: - C7: Path restriction — redirect targets from raw input

extension ScanRules {

    // swiftlint:disable:next force_try
    private static let redirectTargetRegex = try! NSRegularExpression(
        pattern: #">{1,2}\s*(\S+)"#)

    static func c7RedirectPathRestriction(rawInput: String) -> Finding? {
        let range = NSRange(rawInput.startIndex..., in: rawInput)
        let matches = redirectTargetRegex.matches(in: rawInput, range: range)
        for match in matches {
            guard let targetRange = Range(match.range(at: 1), in: rawInput)
            else { continue }
            let target = String(rawInput[targetRange])
            let node = CommandNode(argv: [])
            if let finding = PathRestriction.checkTarget(target, node: node) {
                return finding
            }
        }
        return nil
    }
}
