/// What a skill did, shown in the Overlay after a successful dispatch.
public struct SkillResult: Equatable, Sendable {
    public let summary: String

    public init(summary: String) {
        self.summary = summary
    }
}
