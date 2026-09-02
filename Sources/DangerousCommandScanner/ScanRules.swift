import Foundation

/// Individual structural rule functions that inspect a `CommandNode`'s `argv`.
/// Each returns an optional `Finding`; `nil` means the rule did not match.
///
/// Rules are grouped by severity tier and numbered per LLD §11.
enum ScanRules {

    // MARK: - H1: Privilege escalation

    private static let privEscPrograms: Set<String> = [
        "sudo", "su", "doas", "pkexec", "sudoedit",
    ]

    static func h1PrivilegeEscalation(_ node: CommandNode) -> Finding? {
        guard let cmd = node.argv.first, privEscPrograms.contains(cmd) else { return nil }
        return Finding(
            rule: .privilegeEscalation,
            severity: .hardBlock,
            matchedText: node.argv.joined(separator: " "),
            explanation: "Privilege escalation via \(cmd) is never permitted.",
            path: node.path)
    }

    // MARK: - H2: SIP / security policy tampering

    static func h2SipSecurityPolicy(_ node: CommandNode) -> Finding? {
        guard let cmd = node.argv.first else { return nil }
        switch cmd {
        case "csrutil", "spctl", "bputil":
            return sipFinding(node)
        case "nvram":
            return nvramCheck(node)
        default:
            return nil
        }
    }

    private static func sipFinding(_ node: CommandNode) -> Finding {
        Finding(
            rule: .sipSecurityPolicy,
            severity: .hardBlock,
            matchedText: node.argv.joined(separator: " "),
            explanation: "Modifying SIP/security policy is never permitted.",
            path: node.path)
    }

    private static func nvramCheck(_ node: CommandNode) -> Finding? {
        let args = node.argv.dropFirst()
        let readOnly = args.allSatisfy { $0 == "-p" || $0 == "-x" || $0 == "--print" }
        if args.isEmpty || readOnly { return nil }
        return sipFinding(node)
    }

    // MARK: - H3: Credential exfiltration

    static func h3CredentialExfiltration(_ node: CommandNode) -> Finding? {
        guard node.argv.first == "security" else { return nil }
        let args = Array(node.argv.dropFirst())
        if args.first == "dump-keychain" { return credentialFinding(node) }
        if args.first == "find-generic-password", args.contains("-w") {
            return credentialFinding(node)
        }
        return nil
    }

    private static func credentialFinding(_ node: CommandNode) -> Finding {
        Finding(
            rule: .credentialExfiltration,
            severity: .hardBlock,
            matchedText: node.argv.joined(separator: " "),
            explanation: "Credential exfiltration is never permitted.",
            path: node.path)
    }

    // MARK: - H4: launchctl tampering

    private static let launchctlDangerousSubs: Set<String> = [
        "load", "unload", "bootout", "bootstrap", "enable", "disable",
        "kickstart", "kill",
    ]

    static func h4LaunchctlTampering(_ node: CommandNode) -> Finding? {
        guard node.argv.first == "launchctl" else { return nil }
        let args = Array(node.argv.dropFirst())
        guard let sub = args.first else { return nil }
        guard launchctlDangerousSubs.contains(sub) else { return nil }
        let remainder = args.dropFirst().joined(separator: " ")
        let targetsAide = remainder.contains("aide") || remainder.contains("Aide")
        let targetsSystem =
            remainder.contains("/System/") || remainder.contains("system/")
        guard targetsAide || targetsSystem else { return nil }
        return Finding(
            rule: .launchctlTampering,
            severity: .hardBlock,
            matchedText: node.argv.joined(separator: " "),
            explanation: "Tampering with Aide jobs or system daemons via launchctl is blocked.",
            path: node.path)
    }
}

// MARK: - H5: Disk destruction

extension ScanRules {

    private static let diskutilDangerousSubs: Set<String> = [
        "erase", "eraseDisk", "eraseVolume",
        "reformat", "partitionDisk",
    ]

    static func h5DiskDestruction(_ node: CommandNode) -> Finding? {
        guard let cmd = node.argv.first else { return nil }
        if cmd == "dd" { return ddDeviceCheck(node) }
        if cmd == "diskutil" { return diskutilCheck(node) }
        if cmd.hasPrefix("mkfs") || cmd.hasPrefix("newfs") { return diskFinding(node) }
        if cmd == "asr" { return asrCheck(node) }
        return nil
    }

    private static func ddDeviceCheck(_ node: CommandNode) -> Finding? {
        let hasDeviceOf = node.argv.contains { $0.hasPrefix("of=/dev/") }
        guard hasDeviceOf else { return nil }
        return diskFinding(node)
    }

    private static func diskutilCheck(_ node: CommandNode) -> Finding? {
        guard let sub = node.argv.dropFirst().first else { return nil }
        guard diskutilDangerousSubs.contains(sub) else { return nil }
        return diskFinding(node)
    }

    private static func asrCheck(_ node: CommandNode) -> Finding? {
        guard node.argv.contains("restore") else { return nil }
        return diskFinding(node)
    }

    private static func diskFinding(_ node: CommandNode) -> Finding {
        Finding(
            rule: .diskDestruction,
            severity: .hardBlock,
            matchedText: node.argv.joined(separator: " "),
            explanation: "Disk destruction / reformatting is never permitted.",
            path: node.path)
    }
}

// MARK: - H6: Fork bomb (regex — pattern-based detection)

extension ScanRules {

    // swiftlint:disable:next force_try
    private static let forkBombRegex = try! NSRegularExpression(
        pattern: #":\s*\(\s*\)\s*\{\s*:\s*\|\s*:\s*&\s*\}\s*;\s*:"#)

    static func h6ForkBomb(rawInput: String) -> Finding? {
        let range = NSRange(rawInput.startIndex..., in: rawInput)
        guard forkBombRegex.firstMatch(in: rawInput, range: range) != nil else { return nil }
        return Finding(
            rule: .forkBomb,
            severity: .hardBlock,
            matchedText: rawInput,
            explanation: "Fork bomb — spawns processes until the machine is unusable.")
    }
}

// MARK: - C1: Recursive delete

extension ScanRules {

    private static let dangerousRmTargets: Set<String> = ["/", "~", "*", "."]

    static func c1RecursiveDelete(_ node: CommandNode) -> Finding? {
        guard let cmd = node.argv.first, cmd == "rm" || cmd.hasSuffix("/rm") else { return nil }
        let args = Array(node.argv.dropFirst())
        let isRecursive = hasRecursiveFlag(args)
        let hasDangerousTarget = args.contains { dangerousRmTargets.contains($0) }
        guard isRecursive || hasDangerousTarget else { return nil }
        return Finding(
            rule: .recursiveDelete,
            severity: .confirm,
            matchedText: node.argv.joined(separator: " "),
            explanation: "Recursively deletes files or targets a dangerous path. This is irreversible.",
            path: node.path)
    }

    private static func hasRecursiveFlag(_ args: [String]) -> Bool {
        args.contains { token in
            if token == "--recursive" { return true }
            guard token.hasPrefix("-"), !token.hasPrefix("--") else { return false }
            return token.dropFirst().contains { $0 == "r" || $0 == "R" }
        }
    }
}

// MARK: - C2: Secure erase

extension ScanRules {

    private static let secureErasePrograms: Set<String> = ["srm", "shred"]

    static func c2SecureErase(_ node: CommandNode) -> Finding? {
        guard let cmd = node.argv.first else { return nil }
        if secureErasePrograms.contains(cmd) {
            return secureEraseFinding(node)
        }
        let isRm = cmd == "rm" || cmd.hasSuffix("/rm")
        if isRm, node.argv.dropFirst().contains(where: { $0 == "-P" }) {
            return secureEraseFinding(node)
        }
        return nil
    }

    private static func secureEraseFinding(_ node: CommandNode) -> Finding {
        Finding(
            rule: .secureErase,
            severity: .confirm,
            matchedText: node.argv.joined(separator: " "),
            explanation: "Securely erases files. This is irreversible.",
            path: node.path)
    }
}

// MARK: - C3: Piped remote execution (cross-segment rule)

extension ScanRules {

    private static let downloaders: Set<String> = ["curl", "wget", "fetch"]
    private static let shells: Set<String> = ["sh", "bash", "zsh"]

    static func c3PipedRemoteExecution(
        leftNode: CommandNode, rightNode: CommandNode
    ) -> Finding? {
        guard let leftCmd = leftNode.argv.first, downloaders.contains(leftCmd),
            let rightCmd = rightNode.argv.first, shells.contains(rightCmd)
        else { return nil }
        return Finding(
            rule: .pipedRemoteExecution,
            severity: .confirm,
            matchedText: "\(leftCmd) | \(rightCmd)",
            explanation: "Pipes a downloaded script into a shell (remote code execution).",
            path: rightNode.path)
    }
}

// MARK: - C4: Broad permission change

extension ScanRules {

    private static let broadPaths: Set<String> = ["/", "/usr", "/var", "/etc", "/System"]

    static func c4BroadPermissionChange(_ node: CommandNode) -> Finding? {
        guard let cmd = node.argv.first else { return nil }
        if cmd == "chmod" { return chmodCheck(node) }
        if cmd == "chown" || cmd == "chgrp" { return chownChgrpCheck(node) }
        return nil
    }

    private static func chmodCheck(_ node: CommandNode) -> Finding? {
        let args = Array(node.argv.dropFirst())
        let hasRecursive = args.contains("-R")
        guard hasRecursive else { return nil }
        let has777 = args.contains("777") || args.contains("0777")
        let hasARwx = args.contains("a+rwx")
        guard has777 || hasARwx else { return nil }
        return permFinding(node)
    }

    private static func chownChgrpCheck(_ node: CommandNode) -> Finding? {
        let args = Array(node.argv.dropFirst())
        guard args.contains("-R") else { return nil }
        let hasBroadPath = args.contains { broadPaths.contains($0) }
        guard hasBroadPath else { return nil }
        return permFinding(node)
    }

    private static func permFinding(_ node: CommandNode) -> Finding {
        Finding(
            rule: .broadPermissionChange,
            severity: .confirm,
            matchedText: node.argv.joined(separator: " "),
            explanation: "Broad recursive permission change is dangerous.",
            path: node.path)
    }
}
