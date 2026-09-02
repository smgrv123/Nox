/// Stable identifier for a scanner rule (LLD §11).
///
/// Raw values follow the LLD numbering: H1–H7 for hard-block, C1–C12 for confirm.
public struct RuleID: RawRepresentable, Equatable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

// MARK: - LLD §11.1 Hard-Block

extension RuleID {
    public static let privilegeEscalation = RuleID(rawValue: "H1")
    public static let sipSecurityPolicy = RuleID(rawValue: "H2")
    public static let credentialExfiltration = RuleID(rawValue: "H3")
    public static let launchctlTampering = RuleID(rawValue: "H4")
    public static let diskDestruction = RuleID(rawValue: "H5")
    public static let forkBomb = RuleID(rawValue: "H6")
    public static let aideAutomationEscalation = RuleID(rawValue: "H7")
}

// MARK: - LLD §11.2 Confirm

extension RuleID {
    public static let recursiveDelete = RuleID(rawValue: "C1")
    public static let secureErase = RuleID(rawValue: "C2")
    public static let pipedRemoteExecution = RuleID(rawValue: "C3")
    public static let broadPermissionChange = RuleID(rawValue: "C4")
    public static let ddFileCopy = RuleID(rawValue: "C5")
    public static let broadKill = RuleID(rawValue: "C6")
    public static let outsideHome = RuleID(rawValue: "C7")
    public static let shellProfileEdit = RuleID(rawValue: "C8")
    public static let gitDestructive = RuleID(rawValue: "C9")
    public static let bulkMoveDelete = RuleID(rawValue: "C10")
    public static let dictationIntoTerminal = RuleID(rawValue: "C11")
    public static let unparseable = RuleID(rawValue: "C12")
    public static let obfuscatedExecution = RuleID(rawValue: "C-obfuscation")
}
