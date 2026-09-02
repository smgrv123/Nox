import Foundation

// MARK: - C5: dd file-to-file

extension ScanRules {

    static func c5DdFileCopy(_ node: CommandNode) -> Finding? {
        guard node.argv.first == "dd" else { return nil }
        let hasOf = node.argv.contains { $0.hasPrefix("of=") }
        let isDevice = node.argv.contains { $0.hasPrefix("of=/dev/") }
        guard hasOf, !isDevice else { return nil }
        return Finding(
            rule: .ddFileCopy,
            severity: .confirm,
            matchedText: node.argv.joined(separator: " "),
            explanation: "dd copies raw data between files — confirm this is intentional.",
            path: node.path)
    }
}

// MARK: - C6: Broad kill

extension ScanRules {

    static func c6BroadKill(_ node: CommandNode) -> Finding? {
        guard let cmd = node.argv.first else { return nil }
        if cmd == "kill" { return killCheck(node) }
        if cmd == "killall" || cmd == "pkill" { return killallPkillCheck(node) }
        return nil
    }

    private static func killCheck(_ node: CommandNode) -> Finding? {
        let args = Array(node.argv.dropFirst())
        let hasKillSignal = args.contains { $0 == "-9" || $0 == "-KILL" || $0 == "-SIGKILL" }
        let targetsMinus1 = args.contains("-1")
        guard hasKillSignal, targetsMinus1 else { return nil }
        return broadKillFinding(node)
    }

    private static func killallPkillCheck(_ node: CommandNode) -> Finding? {
        let args = Array(node.argv.dropFirst())
        let has9 = args.contains("-9")
        guard has9 else { return nil }
        return broadKillFinding(node)
    }

    private static func broadKillFinding(_ node: CommandNode) -> Finding {
        Finding(
            rule: .broadKill,
            severity: .confirm,
            matchedText: node.argv.joined(separator: " "),
            explanation: "Broad signal to many processes is dangerous.",
            path: node.path)
    }
}

// MARK: - C8: Shell profile edits

extension ScanRules {

    private static let profileFiles: Set<String> = [
        ".zshrc", ".bashrc", ".bash_profile", ".profile",
        ".zshenv", ".zprofile", ".login", ".bash_login",
    ]

    static func c8ShellProfileEdit(_ node: CommandNode) -> Finding? {
        guard let cmd = node.argv.first else { return nil }
        if cmd == "crontab" { return crontabCheck(node) }
        return profileTargetCheck(node)
    }

    private static func crontabCheck(_ node: CommandNode) -> Finding? {
        let args = Array(node.argv.dropFirst())
        if args.contains("-r") || args.contains("-") {
            return profileFinding(node)
        }
        return nil
    }

    private static func profileTargetCheck(_ node: CommandNode) -> Finding? {
        let allArgs = node.argv.dropFirst()
        let targetsProfile = allArgs.contains { arg in
            profileFiles.contains(where: { arg.hasSuffix($0) })
        }
        guard targetsProfile else { return nil }
        return profileFinding(node)
    }

    private static func profileFinding(_ node: CommandNode) -> Finding {
        Finding(
            rule: .shellProfileEdit,
            severity: .confirm,
            matchedText: node.argv.joined(separator: " "),
            explanation: "Modifying shell profiles or crontab can alter system behavior.",
            path: node.path)
    }
}

// MARK: - C9: Git destructive

extension ScanRules {

    static func c9GitDestructive(_ node: CommandNode) -> Finding? {
        guard node.argv.first == "git", node.argv.count >= 2 else { return nil }
        let sub = node.argv[1]
        switch sub {
        case "clean": return gitCleanCheck(node)
        case "reset": return gitResetCheck(node)
        case "push": return gitPushForceCheck(node)
        default: return nil
        }
    }

    private static func gitCleanCheck(_ node: CommandNode) -> Finding? {
        let flags = node.argv.dropFirst(2)
        let hasFd = flags.contains(where: { flagString in
            flagString.hasPrefix("-") && !flagString.hasPrefix("--")
                && flagString.contains("f") && flagString.contains("d")
        })
        guard hasFd else { return nil }
        return gitFinding(node)
    }

    private static func gitResetCheck(_ node: CommandNode) -> Finding? {
        let args = Array(node.argv.dropFirst(2))
        guard args.contains("--hard") else { return nil }
        return gitFinding(node)
    }

    private static func gitPushForceCheck(_ node: CommandNode) -> Finding? {
        let args = Array(node.argv.dropFirst(2))
        let hasForce =
            args.contains("--force") || args.contains("-f")
            || args.contains("--force-with-lease")
        guard hasForce else { return nil }
        return gitFinding(node)
    }

    private static func gitFinding(_ node: CommandNode) -> Finding {
        Finding(
            rule: .gitDestructive,
            severity: .confirm,
            matchedText: node.argv.joined(separator: " "),
            explanation: "Destructive git operation — may cause irreversible data loss.",
            path: node.path)
    }
}

// MARK: - C10: Bulk move/delete (find -delete, find -exec rm)

extension ScanRules {

    static func c10BulkMoveDelete(_ node: CommandNode) -> Finding? {
        guard node.argv.first == "find" else { return nil }
        let hasDelete = node.argv.contains("-delete")
        let hasExecRm = findExecTargetsRm(node.argv)
        guard hasDelete || hasExecRm else { return nil }
        return Finding(
            rule: .bulkMoveDelete,
            severity: .confirm,
            matchedText: node.argv.joined(separator: " "),
            explanation: "Bulk file deletion via find is dangerous.",
            path: node.path)
    }

    private static func findExecTargetsRm(_ argv: [String]) -> Bool {
        guard let execIdx = argv.firstIndex(where: { $0 == "-exec" || $0 == "-execdir" })
        else { return false }
        let next = argv.index(after: execIdx)
        guard next < argv.count else { return false }
        return argv[next] == "rm" || argv[next].hasSuffix("/rm")
    }
}

// MARK: - C8 redirect-to-profile detection

extension ScanRules {

    static func c8RedirectToProfile(rawInput: String) -> Finding? {
        let pattern = #">>\s*~/?\.(zshrc|bashrc|bash_profile|profile|zshenv|zprofile)"#
        // swiftlint:disable:next force_try
        let regex = try! NSRegularExpression(pattern: pattern)
        let range = NSRange(rawInput.startIndex..., in: rawInput)
        guard regex.firstMatch(in: rawInput, range: range) != nil else { return nil }
        return Finding(
            rule: .shellProfileEdit,
            severity: .confirm,
            matchedText: rawInput,
            explanation: "Appending to a shell profile can alter system behavior.")
    }
}
