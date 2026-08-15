import Foundation

/// One turn of a free-form chat conversation (docs/05-lld.md §3.3; plan Phase 3; User
/// Stories 1, 5, 19) — the `messages` element `LLMClient.chat` sends alongside its own
/// separate `system` string. `role` mirrors the OpenAI-compatible wire vocabulary
/// `InferenceClient` talks on the loopback Sidecar (and, unexercised in this phase, a
/// BYOK cloud endpoint sharing the same shape).
public struct ChatMessage: Equatable, Sendable {

    public enum Role: String, Equatable, Sendable {
        case system
        case user
        case assistant
    }

    public let role: Role
    public let content: String

    public init(role: Role, content: String) {
        self.role = role
        self.content = content
    }
}
