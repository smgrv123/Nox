/// A single token emitted by the shell lexer (LLD §4.3 Phase A).
public enum ShellToken: Equatable, Sendable {
    case word(String)
    case `operator`(Operator)
    case substitution(SubstitutionKind, [ShellToken])
    case opaque(String)

    public enum Operator: String, Equatable, Sendable {
        case pipe = "|"
        case or = "||"
        case background = "&"
        case and = "&&"
        case semi = ";"
        case leftParen = "("
        case rightParen = ")"
        case leftBrace = "{"
        case rightBrace = "}"
        case redirectIn = "<"
        case redirectOut = ">"
        case redirectAppend = ">>"
        case newline = "\n"
    }

    public enum SubstitutionKind: String, Equatable, Sendable {
        case dollarParen = "$("
        case backtick = "`"
    }
}
