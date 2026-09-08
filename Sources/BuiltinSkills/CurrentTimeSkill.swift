import CommandDispatcher
import Foundation
import SkillManifest

enum CurrentTimeSkill {
    static func run(parameters: JSONValue, now: Date) throws -> SkillResult {
        let name = ParameterReader.optionalString("timezone", in: parameters)
        let timeZone = try resolveTimeZone(name)
        let formatted = format(now, in: timeZone)
        if let name {
            return SkillResult(summary: "The time in \(name) is \(formatted)")
        }
        return SkillResult(summary: "The local time is \(formatted)")
    }

    private static func resolveTimeZone(_ name: String?) throws -> TimeZone {
        guard let name else { return .current }
        guard let timeZone = TimeZone(identifier: name) else {
            throw SkillExecutionError.unknownTimezone(name)
        }
        return timeZone
    }

    private static func format(_ date: Date, in timeZone: TimeZone) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = timeZone
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
