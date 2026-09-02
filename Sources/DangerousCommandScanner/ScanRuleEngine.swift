import Foundation

/// Structured rule engine that evaluates a parsed command tree and context,
/// producing a `ScanVerdict` (LLD §4.3 Phase C + Phase D).
enum ScanRuleEngine {

    static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable",
        "com.mitchellh.ghostty", "net.kovidgoyal.kitty", "org.alacritty",
        "com.github.wez.wezterm",
    ]

    /// C1–C10 rule IDs that H7 (Aide automation) escalates to hard-block.
    private static let h7EscalationTargets: Set<RuleID> = [
        .recursiveDelete, .secureErase, .pipedRemoteExecution,
        .broadPermissionChange, .ddFileCopy, .broadKill,
        .outsideHome, .shellProfileEdit, .gitDestructive, .bulkMoveDelete,
    ]

    // MARK: - Entry point

    static func evaluate(
        parseResult: CommandTreeParser.ParseResult,
        rawInput: String,
        context: ScanContext
    ) -> ScanVerdict {
        var findings = parseResult.findings
        let allNodes = parseResult.allNodes

        evaluatePerNodeRules(allNodes, findings: &findings)
        evaluateCrossSegmentRules(parseResult.nodes, findings: &findings)
        evaluateRawInputRules(rawInput, findings: &findings)
        applyH7Escalation(context: context, findings: &findings)
        applyC11Dictation(context: context, findings: &findings)
        return combineVerdict(findings)
    }

    // MARK: - Per-node rules

    private static func evaluatePerNodeRules(
        _ nodes: [CommandNode], findings: inout [Finding]
    ) {
        for node in nodes {
            evaluateSingleNode(node, findings: &findings)
        }
    }

    private static func evaluateSingleNode(
        _ node: CommandNode, findings: inout [Finding]
    ) {
        let nodeRules: [(CommandNode) -> Finding?] = [
            ScanRules.h1PrivilegeEscalation,
            ScanRules.h2SipSecurityPolicy,
            ScanRules.h3CredentialExfiltration,
            ScanRules.h4LaunchctlTampering,
            ScanRules.h5DiskDestruction,
            ScanRules.c1RecursiveDelete,
            ScanRules.c2SecureErase,
            ScanRules.c4BroadPermissionChange,
            ScanRules.c5DdFileCopy,
            ScanRules.c6BroadKill,
            ScanRules.c8ShellProfileEdit,
            ScanRules.c9GitDestructive,
            ScanRules.c10BulkMoveDelete,
        ]
        for rule in nodeRules {
            if let finding = rule(node) {
                findings.append(finding)
            }
        }
    }
}

// MARK: - Cross-segment, raw-input, and context rules

extension ScanRuleEngine {

    private static func evaluateCrossSegmentRules(
        _ topNodes: [CommandNode], findings: inout [Finding]
    ) {
        guard topNodes.count >= 2 else { return }
        for idx in 0..<(topNodes.count - 1) {
            let left = topNodes[idx]
            let right = topNodes[idx + 1]
            let isPiped = right.path.last == "pipe"
            guard isPiped else { continue }
            if let finding = ScanRules.c3PipedRemoteExecution(leftNode: left, rightNode: right) {
                findings.append(finding)
            }
        }
    }

    private static func evaluateRawInputRules(
        _ rawInput: String, findings: inout [Finding]
    ) {
        if let finding = ScanRules.h6ForkBomb(rawInput: rawInput) {
            findings.append(finding)
        }
        if let finding = ScanRules.c8RedirectToProfile(rawInput: rawInput) {
            findings.append(finding)
        }
    }

    private static func applyH7Escalation(
        context: ScanContext, findings: inout [Finding]
    ) {
        guard context.manifestID != nil else { return }
        let hasEscalatableFindings = findings.contains {
            $0.severity == .confirm && h7EscalationTargets.contains($0.rule)
        }
        guard hasEscalatableFindings else { return }
        findings.append(
            Finding(
                rule: .aideAutomationEscalation,
                severity: .hardBlock,
                matchedText: "manifestID=\(context.manifestID ?? "")",
                explanation:
                    "Aide-generated automation: destructive commands escalated to hard-block (H7)."
            ))
    }

    private static func applyC11Dictation(
        context: ScanContext, findings: inout [Finding]
    ) {
        guard context.channel == .dictatedOneOff,
            let bundleID = context.destinationBundleID,
            terminalBundleIDs.contains(bundleID)
        else { return }
        findings.append(
            Finding(
                rule: .dictationIntoTerminal,
                severity: .confirm,
                matchedText: "dictation → \(bundleID)",
                explanation: "Voice-dictated command targeting a terminal requires confirmation."
            ))
    }
}

// MARK: - Verdict combiner

extension ScanRuleEngine {

    static func combineVerdict(_ findings: [Finding]) -> ScanVerdict {
        let hasHardBlock = findings.contains { $0.severity == .hardBlock }
        if hasHardBlock { return .hardBlock(findings: findings) }
        let hasConfirm = findings.contains { $0.severity == .confirm }
        if hasConfirm { return .confirm(findings: findings) }
        return .clean
    }
}
