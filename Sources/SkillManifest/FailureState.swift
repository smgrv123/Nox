import Foundation

/// Mutable runtime state tracking consecutive execution failures.
///
/// Auto-disables the skill after `maxConsecutiveFailures` are reached.
/// Persisted back into the manifest JSON.
public struct FailureState: Codable, Sendable, Hashable {
    public var consecutiveFailures: Int
    public var maxConsecutiveFailures: Int
    public var lastFailureAt: Date?
    public var lastSuccessAt: Date?
    public var autoDisabled: Bool

    public init(
        consecutiveFailures: Int = 0,
        maxConsecutiveFailures: Int = 3,
        lastFailureAt: Date? = nil,
        lastSuccessAt: Date? = nil,
        autoDisabled: Bool = false
    ) {
        self.consecutiveFailures = consecutiveFailures
        self.maxConsecutiveFailures = maxConsecutiveFailures
        self.lastFailureAt = lastFailureAt
        self.lastSuccessAt = lastSuccessAt
        self.autoDisabled = autoDisabled
    }
}
