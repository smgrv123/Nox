import Foundation

/// The type of schedule trigger for a scheduled skill.
public enum ScheduleType: String, Codable, Sendable, Hashable {
    case interval
    case calendar
}

/// A launchd-style calendar interval specification.
public struct CalendarSchedule: Codable, Sendable, Hashable {
    public var minute: Int?
    public var hour: Int?
    public var day: Int?
    public var weekday: Int?
    public var month: Int?

    public init(
        minute: Int? = nil,
        hour: Int? = nil,
        day: Int? = nil,
        weekday: Int? = nil,
        month: Int? = nil
    ) {
        self.minute = minute
        self.hour = hour
        self.day = day
        self.weekday = weekday
        self.month = month
    }
}

/// Optional trigger schedule for a skill: interval-based or calendar-based.
public struct ManifestSchedule: Codable, Sendable, Hashable {
    public var type: ScheduleType
    public var intervalSeconds: Int?
    public var calendar: CalendarSchedule?
    public var runAtLoad: Bool

    public init(
        type: ScheduleType,
        intervalSeconds: Int? = nil,
        calendar: CalendarSchedule? = nil,
        runAtLoad: Bool = false
    ) {
        self.type = type
        self.intervalSeconds = intervalSeconds
        self.calendar = calendar
        self.runAtLoad = runAtLoad
    }
}
