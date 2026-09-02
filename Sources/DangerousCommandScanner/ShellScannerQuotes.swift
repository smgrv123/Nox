/// Quoted-string internals for the shell scanner — single quotes, double quotes,
/// and `$'...'` ANSI-C quoting with escape decoding.
extension ShellScanner {

    mutating func scanUntilSingleQuoteClose() -> String? {
        var content = ""
        while pos < chars.count {
            if chars[pos] == "'" {
                pos += 1
                return content
            }
            content.append(chars[pos])
            pos += 1
        }
        return nil
    }

    mutating func scanUntilDoubleQuoteClose() -> String? {
        var content = ""
        while pos < chars.count {
            let ch = chars[pos]
            if ch == "\"" {
                pos += 1
                return content
            }
            if ch == "\\" {
                content += scanDoubleQuoteBackslash()
                continue
            }
            if ch == "$", peek(1) == "(" {
                flushDoubleQuoteText(content)
                content = ""
                scanDollarParenSubstitution()
                continue
            }
            if ch == "`" {
                flushDoubleQuoteText(content)
                content = ""
                scanBacktickSubstitution()
                continue
            }
            content.append(ch)
            pos += 1
        }
        return nil
    }

    private mutating func flushDoubleQuoteText(_ text: String) {
        if !text.isEmpty {
            tokens.append(.word(text))
        }
    }

    private mutating func scanDoubleQuoteBackslash() -> String {
        guard pos + 1 < chars.count else {
            pos += 1
            return "\\"
        }
        let next = chars[pos + 1]
        if next == "\\" || next == "\"" || next == "$" || next == "`" || next == "\n" {
            pos += 2
            return String(next)
        }
        pos += 2
        return "\\" + String(next)
    }

    mutating func scanUntilAnsiCQuoteClose() -> String? {
        var content = ""
        while pos < chars.count {
            let ch = chars[pos]
            if ch == "'" {
                pos += 1
                return content
            }
            if ch == "\\" {
                pos += 1
                guard pos < chars.count else { return nil }
                content += scanAnsiCEscape()
                continue
            }
            content.append(ch)
            pos += 1
        }
        return nil
    }

    // MARK: - ANSI-C escape decoding

    private static let simpleEscapes: [Character: Character] = [
        "n": "\n", "t": "\t", "r": "\r",
        "a": "\u{07}", "b": "\u{08}", "f": "\u{0C}", "v": "\u{0B}",
        "e": "\u{1B}", "E": "\u{1B}",
        "\\": "\\", "'": "'", "\"": "\"",
    ]

    private mutating func scanAnsiCEscape() -> String {
        let esc = chars[pos]
        if let simple = Self.simpleEscapes[esc] {
            pos += 1
            return String(simple)
        }
        switch esc {
        case "x":
            pos += 1
            if let scalar = scanHexEscape(maxDigits: 2) { return String(Character(scalar)) }
        case "u":
            pos += 1
            if let scalar = scanHexEscape(maxDigits: 4) { return String(Character(scalar)) }
        case "U":
            pos += 1
            if let scalar = scanHexEscape(maxDigits: 8) { return String(Character(scalar)) }
        case "0"..."7":
            if let scalar = scanOctalEscape() { return String(Character(scalar)) }
        default:
            pos += 1
            return "\\" + String(esc)
        }
        return ""
    }

    private mutating func scanHexEscape(maxDigits: Int) -> Unicode.Scalar? {
        var hex = ""
        var count = 0
        while count < maxDigits, pos < chars.count, chars[pos].isHexDigit {
            hex.append(chars[pos])
            pos += 1
            count += 1
        }
        guard !hex.isEmpty, let value = UInt32(hex, radix: 16),
            let scalar = Unicode.Scalar(value)
        else { return nil }
        return scalar
    }

    private mutating func scanOctalEscape() -> Unicode.Scalar? {
        var octal = ""
        for _ in 0..<3 {
            guard pos < chars.count, let digit = chars[pos].asciiValue,
                (0x30...0x37).contains(digit)
            else { break }
            octal.append(chars[pos])
            pos += 1
        }
        guard !octal.isEmpty, let value = UInt32(octal, radix: 8),
            let scalar = Unicode.Scalar(value)
        else { return nil }
        return scalar
    }
}
