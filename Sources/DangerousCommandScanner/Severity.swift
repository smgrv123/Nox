/// Two-tier severity for dangerous-command scanner findings (LLD §3.6, §11).
public enum Severity: String, Equatable, Hashable, Sendable {
    case hardBlock
    case confirm
}
