import CommandDispatcher
import Foundation
import SkillManifest

enum CalculateSkill {
    static func run(parameters: JSONValue) throws -> SkillResult {
        let expression = try ParameterReader.requiredString("expression", in: parameters)
        switch ExpressionEvaluator.evaluate(expression) {
        case .success(let value):
            return SkillResult(summary: NumberFormatting.display(value))
        case .failure(let error):
            return SkillResult(summary: error.userMessage)
        }
    }
}

enum ExpressionEvaluator {
    static func evaluate(_ source: String) -> Result<Double, ExpressionError> {
        do {
            var tokenizer = ExpressionTokenizer(source)
            let tokens = try tokenizer.tokenize()
            var parser = ExpressionParser(tokens: tokens)
            let value = try parser.evaluate()
            guard value.isFinite else { return .failure(.divisionByZero) }
            return .success(value)
        } catch let error as ExpressionError {
            return .failure(error)
        } catch {
            return .failure(.unexpectedToken)
        }
    }
}

enum NumberFormatting {
    static func display(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 10
        formatter.minimumFractionDigits = 0
        formatter.usesGroupingSeparator = false
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}
