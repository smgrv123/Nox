struct ExpressionTokenizer {
    private let chars: [Character]
    private var index = 0

    init(_ source: String) {
        self.chars = Array(source)
    }

    mutating func tokenize() throws -> [ExpressionToken] {
        var tokens: [ExpressionToken] = []
        while let token = try nextToken() {
            tokens.append(token)
        }
        guard !tokens.isEmpty else { throw ExpressionError.empty }
        return tokens
    }

    private mutating func nextToken() throws -> ExpressionToken? {
        skipWhitespace()
        guard index < chars.count else { return nil }
        let character = chars[index]
        if character.isNumber { return try number() }
        if character.isLetter { return try identifier() }
        index += 1
        return try symbol(character)
    }

    private mutating func skipWhitespace() {
        while index < chars.count && chars[index].isWhitespace {
            index += 1
        }
    }

    private mutating func number() throws -> ExpressionToken {
        let start = index
        var sawDot = false
        while index < chars.count {
            let character = chars[index]
            if character.isNumber {
                index += 1
            } else if character == "." && !sawDot {
                sawDot = true
                index += 1
            } else {
                break
            }
        }
        let raw = String(chars[start..<index])
        guard let value = Double(raw) else { throw ExpressionError.unexpectedToken }
        return .number(value)
    }

    private mutating func identifier() throws -> ExpressionToken {
        let start = index
        while index < chars.count && chars[index].isLetter {
            index += 1
        }
        let raw = String(chars[start..<index]).lowercased()
        guard raw == "of" else { throw ExpressionError.unexpectedToken }
        return .of
    }

    private func symbol(_ character: Character) throws -> ExpressionToken {
        switch character {
        case "+": return .plus
        case "-": return .minus
        case "*": return .star
        case "/": return .slash
        case "%": return .percent
        case "(": return .lParen
        case ")": return .rParen
        default: throw ExpressionError.unexpectedCharacter(character)
        }
    }
}
