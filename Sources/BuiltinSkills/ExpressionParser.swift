struct ExpressionParser {
    private let tokens: [ExpressionToken]
    private var index = 0

    init(tokens: [ExpressionToken]) {
        self.tokens = tokens
    }

    mutating func evaluate() throws -> Double {
        let value = try expression()
        guard index == tokens.count else { throw ExpressionError.trailingGarbage }
        return value
    }

    private mutating func expression() throws -> Double {
        var value = try term()
        while true {
            if match(.plus) {
                value += try term()
            } else if match(.minus) {
                value -= try term()
            } else {
                return value
            }
        }
    }

    private mutating func term() throws -> Double {
        var value = try unary()
        while true {
            if match(.star) {
                value *= try unary()
            } else if match(.slash) {
                value = try divide(value, by: try unary())
            } else if match(.percent) {
                value = try modulo(value, by: try unary())
            } else {
                return value
            }
        }
    }

    private mutating func unary() throws -> Double {
        if match(.minus) { return try -unary() }
        return try primary()
    }

    private mutating func primary() throws -> Double {
        if match(.lParen) {
            let value = try expression()
            guard match(.rParen) else { throw ExpressionError.unmatchedParen }
            return value
        }
        guard case .number(let number) = peek() else {
            throw ExpressionError.missingOperand
        }
        advance()
        return try applyPercentOf(number)
    }

    private mutating func applyPercentOf(_ number: Double) throws -> Double {
        guard peek() == .percent, peek(offset: 1) == .of else { return number }
        advance()
        advance()
        return (number * (try unary())) / 100
    }

    private func divide(_ lhs: Double, by rhs: Double) throws -> Double {
        guard rhs != 0 else { throw ExpressionError.divisionByZero }
        return lhs / rhs
    }

    private func modulo(_ lhs: Double, by rhs: Double) throws -> Double {
        guard rhs != 0 else { throw ExpressionError.divisionByZero }
        return lhs.truncatingRemainder(dividingBy: rhs)
    }

    private func peek(offset: Int = 0) -> ExpressionToken? {
        let target = index + offset
        guard target < tokens.count else { return nil }
        return tokens[target]
    }

    private mutating func advance() {
        index += 1
    }

    private mutating func match(_ token: ExpressionToken) -> Bool {
        guard peek() == token else { return false }
        advance()
        return true
    }
}
