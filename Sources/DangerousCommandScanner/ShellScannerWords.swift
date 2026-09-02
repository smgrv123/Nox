/// Bare-word scanning — handles unquoted content, inline quotes, backslash
/// escapes, `$()` / backtick substitution boundaries, and `$'...'` ANSI-C quoting.
extension ShellScanner {

    private enum WordStep { case keepGoing, done }

    mutating func scanBareWord() {
        var content = ""
        var hasQuotedContent = false
        while pos < chars.count {
            if isWordBreak(chars[pos]) { break }
            if advanceBareWordChar(content: &content, hasQuotedContent: &hasQuotedContent) == .done {
                return
            }
        }
        if !content.isEmpty || hasQuotedContent {
            tokens.append(.word(content))
        }
    }

    private mutating func advanceBareWordChar(
        content: inout String, hasQuotedContent: inout Bool
    ) -> WordStep {
        switch chars[pos] {
        case "'", "\"":
            if scanInlineQuote(opener: chars[pos], content: &content) {
                hasQuotedContent = true
            } else {
                return .done
            }
        case "\\":
            if !scanBareBackslash(content: &content) { return .done }
        case "$":
            if !scanBareDollar(content: &content, hasQuotedContent: &hasQuotedContent) { return .done }
        case "`":
            emitWordIfNeeded(content)
            scanBacktickSubstitution()
            return .done
        case "\0":
            emitWordIfNeeded(content)
            tokens.append(.opaque(String(chars[pos])))
            pos += 1
            return .done
        default:
            content.append(chars[pos])
            pos += 1
        }
        return .keepGoing
    }

    private func isWordBreak(_ ch: Character) -> Bool {
        switch ch {
        case " ", "\t", "\n": return true
        case "|", "&", ";", "(", ")", "{", "}", "<", ">": return true
        case "#" where isCommentStart(): return true
        default: return false
        }
    }

    private mutating func emitWordIfNeeded(_ content: String) {
        if !content.isEmpty {
            tokens.append(.word(content))
        }
    }

    /// Returns `true` if the quote was terminated (content appended), `false` if
    /// unterminated (opaque token emitted, caller should return).
    private mutating func scanInlineQuote(opener: Character, content: inout String) -> Bool {
        let quoteStart = pos
        pos += 1
        let literal = opener == "'" ? scanUntilSingleQuoteClose() : scanUntilDoubleQuoteClose()
        if let literal {
            content += literal
            return true
        }
        let consumed = String(chars[quoteStart...])
        tokens.append(.opaque(content.isEmpty ? consumed : content + consumed))
        return false
    }

    /// Returns `true` to continue the word loop, `false` if the word ended.
    private mutating func scanBareBackslash(content: inout String) -> Bool {
        if pos + 1 < chars.count {
            let next = chars[pos + 1]
            if next == "\n" {
                pos += 2
            } else {
                content.append(next)
                pos += 2
            }
            return true
        }
        pos += 1
        tokens.append(.opaque(content.isEmpty ? "\\" : content + "\\"))
        return false
    }

    /// Returns `true` to continue the word loop, `false` if the word ended.
    private mutating func scanBareDollar(
        content: inout String, hasQuotedContent: inout Bool
    ) -> Bool {
        if peek(1) == "(" {
            emitWordIfNeeded(content)
            scanDollarParenSubstitution()
            return false
        }
        if peek(1) == "'" {
            let quoteStart = pos
            pos += 2
            if let literal = scanUntilAnsiCQuoteClose() {
                hasQuotedContent = true
                content += literal
                return true
            }
            let consumed = String(chars[quoteStart...])
            tokens.append(.opaque(content.isEmpty ? consumed : content + consumed))
            return false
        }
        content.append("$")
        pos += 1
        return true
    }
}
