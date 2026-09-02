/// Outcome of scanning a single command or script (LLD §3.6, §4.3 Phase D).
///
/// Three-tier model: `.clean` (safe), `.confirm` (dangerous but overridable via
/// a distinct destructive-styled confirmation), `.hardBlock` (privilege escalation
/// or Aide-generated automation — no override path in v1).
public enum ScanVerdict: Equatable, Sendable {
    case clean
    case confirm(findings: [Finding])
    case hardBlock(findings: [Finding])

    public var isBlocked: Bool {
        switch self {
        case .clean: return false
        case .confirm, .hardBlock: return true
        }
    }

    public var findings: [Finding] {
        switch self {
        case .clean: return []
        case .confirm(let findings), .hardBlock(let findings): return findings
        }
    }
}
