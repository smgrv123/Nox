/// Character-by-character scanner state for the shell tokenizer.
///
/// Split across `ShellScanner.swift` (core loop + operators),
/// `ShellScannerWords.swift` (bare words + inline quotes),
/// and `ShellScannerQuotes.swift` (quoted-string internals + ANSI-C escapes)
/// to keep each file under lint limits.
struct ShellScanner {
    private(set) var chars: [Character]
    var pos: Int
    var tokens: [ShellToken]

    init(_ input: String) {
        self.chars = Array(input)
        self.pos = 0
        self.tokens = []
    }

    mutating func scanTokens() -> [ShellToken] {
        while pos < chars.count {
            skipWhitespace()
            guard pos < chars.count else { break }
            scanNextToken()
        }
        return tokens
    }

    private mutating func scanNextToken() {
        let ch = chars[pos]
        switch ch {
        case "#" where isCommentStart():
            skipComment()
        case "\n":
            tokens.append(.operator(.newline))
            pos += 1
        case "|", "&", ";", "(", ")", "{", "}", "<", ">":
            scanOperator()
        case "\0":
            tokens.append(.opaque(String(ch)))
            pos += 1
        default:
            scanBareWord()
        }
    }

    // MARK: - Whitespace & comments

    private mutating func skipWhitespace() {
        while pos < chars.count, chars[pos] == " " || chars[pos] == "\t" {
            pos += 1
        }
    }

    func isCommentStart() -> Bool {
        pos == 0 || chars[pos - 1] == " " || chars[pos - 1] == "\t"
            || chars[pos - 1] == "\n" || chars[pos - 1] == ";"
    }

    private mutating func skipComment() {
        while pos < chars.count, chars[pos] != "\n" {
            pos += 1
        }
    }

    // MARK: - Operators

    private mutating func scanOperator() {
        let ch = chars[pos]
        switch ch {
        case "|":
            appendOperator(peek(1) == "|" ? (.or, 2) : (.pipe, 1))
        case "&":
            appendOperator(peek(1) == "&" ? (.and, 2) : (.background, 1))
        case ";":
            appendOperator((.semi, 1))
        case "(":
            appendOperator((.leftParen, 1))
        case ")":
            appendOperator((.rightParen, 1))
        case "{":
            appendOperator((.leftBrace, 1))
        case "}":
            appendOperator((.rightBrace, 1))
        case ">":
            appendOperator(peek(1) == ">" ? (.redirectAppend, 2) : (.redirectOut, 1))
        case "<":
            appendOperator((.redirectIn, 1))
        default:
            pos += 1
        }
    }

    private mutating func appendOperator(_ pair: (ShellToken.Operator, Int)) {
        tokens.append(.operator(pair.0))
        pos += pair.1
    }

    // MARK: - Command substitution

    mutating func scanDollarParenSubstitution() {
        let start = pos
        pos += 2
        var depth = 1
        var inner = ""
        while pos < chars.count, depth > 0 {
            let ch = chars[pos]
            if ch == "(" && pos >= 2 && chars[pos - 1] == "$" {
                depth += 1
            } else if ch == ")" {
                depth -= 1
                if depth == 0 {
                    pos += 1
                    let innerTokens = ShellTokenizer.tokenize(inner)
                    tokens.append(.substitution(.dollarParen, innerTokens))
                    return
                }
            }
            inner.append(ch)
            pos += 1
        }
        tokens.append(.opaque(String(chars[start...])))
    }

    mutating func scanBacktickSubstitution() {
        let start = pos
        pos += 1
        var inner = ""
        while pos < chars.count {
            if chars[pos] == "`" {
                pos += 1
                let innerTokens = ShellTokenizer.tokenize(inner)
                tokens.append(.substitution(.backtick, innerTokens))
                return
            }
            if chars[pos] == "\\" && peek(1) == "`" {
                inner.append("`")
                pos += 2
                continue
            }
            inner.append(chars[pos])
            pos += 1
        }
        tokens.append(.opaque(String(chars[start...])))
    }

    // MARK: - Helpers

    func peek(_ offset: Int) -> Character? {
        let target = pos + offset
        guard target < chars.count else { return nil }
        return chars[target]
    }
}
