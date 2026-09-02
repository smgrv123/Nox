enum ExpressionToken: Equatable {
    case number(Double)
    case plus
    case minus
    case star
    case slash
    case percent
    case lParen
    case rParen
    case of
}

enum ExpressionError: Error, Equatable {
    case empty
    case unexpectedCharacter(Character)
    case unexpectedToken
    case trailingGarbage
    case missingOperand
    case divisionByZero
    case unmatchedParen

    var userMessage: String {
        switch self {
        case .divisionByZero:
            return "Couldn't evaluate that expression: division by zero."
        default:
            return "Couldn't evaluate that expression."
        }
    }
}
