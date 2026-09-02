import Foundation

/// Failures from ``LocalCommandRouter`` that are not parse or confidence errors.
public enum RoutingError: Error, Equatable, Sendable {
    /// The Router must stay on-device (user story 6). A cloud `LLMEndpoint`
    /// is refused — no implicit off-box escalation.
    case cloudEndpointRejected
}
