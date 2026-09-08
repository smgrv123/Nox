import SkillManifest

/// Maps a built-in skill id + parameters to a command string the
/// Dangerous-Command Scanner can inspect. Returns `nil` for pure compute
/// skills (`calculate`, `current_time`) and Q&A stubs (`general_qa`,
/// `screen_qa`) — those never produce a shell command.
public enum ExecutableCommandRenderer: Sendable {

    /// Built-ins that produce an OS-side command the scanner must see.
    public static let executableSkillIDs: Set<String> = [
        "open_application",
        "quit_application",
        "set_timer",
        "media_control",
        "take_screenshot",
    ]

    /// Built-ins that are value-in → value-out (no executable channel).
    public static let pureSkillIDs: Set<String> = [
        "calculate",
        "current_time",
        "general_qa",
        "screen_qa",
        "unit_conversion",
    ]

    public static func isExecutable(_ skillID: String) -> Bool {
        executableSkillIDs.contains(skillID)
    }

    /// Deterministic reconstruction, or `nil` when the skill is not executable.
    public static func render(skillID: String, parameters: JSONValue) -> String? {
        guard isExecutable(skillID) else { return nil }
        switch skillID {
        case "open_application":
            return "open -a \(quoted(stringParam("app_name", in: parameters)))"
        case "quit_application":
            return "osascript -e 'quit app \(quoted(stringParam("app_name", in: parameters)))'"
        case "set_timer":
            let seconds = parameters["duration_seconds"]?.intValue ?? 0
            return "sleep \(seconds)"
        case "media_control":
            let action = stringParam("action", in: parameters)
            return "osascript -e 'tell application \"Music\" to \(action)'"
        case "take_screenshot":
            return "screencapture -x ~/Desktop/aide-screenshot.png"
        default:
            return nil
        }
    }

    private static func stringParam(_ key: String, in parameters: JSONValue) -> String {
        parameters[key]?.stringValue ?? ""
    }

    private static func quoted(_ value: String) -> String {
        "\"\(value)\""
    }
}
