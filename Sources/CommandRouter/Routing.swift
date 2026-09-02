import Foundation
import LLMRuntime

/// DI seam for Command Mode routing (P4 Phase 3). A conformer turns a transcript
/// into a ``RoutedIntent`` by calling `LLMClient.routeComplete` on the
/// caller-supplied **local** endpoint, parsing Contract v2, and deriving
/// ``RoutingConfidence``. No SkillRegistry dependency — catalog and grammar are
/// injected as strings.
public protocol Routing: Sendable {
    /// Route `transcript` against `endpoint`. `whisperAvgLogprob` is accepted for
    /// the downstream calibration record (LLD §4.2); Phase 3 does not gate on it.
    func route(
        transcript: String,
        whisperAvgLogprob: Float,
        endpoint: LLMEndpoint
    ) async throws -> RoutedIntent
}
