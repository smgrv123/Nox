import Foundation
import ModelProvisioning

/// A minimal placeholder for the real `LLMEndpoint` (docs/05-lld.md §3.3) — building
/// out the full `LLMClient`/`InferenceClient` seam is explicitly Phase 3's job. Just
/// enough shape to satisfy `SidecarController.endpoint` here: the loopback base URL a
/// future `InferenceClient` would target once the Sidecar is `.ready`.
///
/// `apiKeyRef` is `String?` rather than LLD §3.3's `KeychainRef?` — that type doesn't
/// exist yet anywhere in the codebase (P6 introduces real Keychain-backed storage for
/// BYOK cloud keys). It is always `nil` for the local Sidecar target this phase
/// produces; Phase 3/P6 can widen this to the real type with no change to
/// `SidecarController` conformers.
public struct LLMEndpoint: Equatable, Sendable {
    public let baseURL: URL
    public let apiKeyRef: String?
    public let model: String
    /// Drives the future Local/Cloud Indicator (docs/04-hld.md §4.2). Always `true`
    /// here — P2b never targets a real cloud endpoint (that's P6).
    public let isLocal: Bool

    public init(baseURL: URL, apiKeyRef: String? = nil, model: String, isLocal: Bool) {
        self.baseURL = baseURL
        self.apiKeyRef = apiKeyRef
        self.model = model
        self.isLocal = isLocal
    }
}

/// Manages the sole Sidecar (docs/05-lld.md §3.4/§5.1 — normative; locked decision 3).
/// `Actor`-constrained: lifecycle transitions must be serialized (docs/05-lld.md §10).
///
/// `SidecarLifecycleController` (this module) is the full, generic, test-first
/// conformer; `SidecarManager` (App/, plan Phase 2's "Architectural decisions")
/// configures it with the real `llama-server` process source and a real clock.
public protocol SidecarController: Actor {
    /// The current lifecycle state (docs/05-lld.md §5.1).
    var state: SidecarState { get }
    /// The local Sidecar's endpoint — valid **only** while `state` is `.ready`.
    var endpoint: LLMEndpoint? { get }

    /// Idempotent: a no-op if a launch/retry cycle is already in flight or `.ready`.
    func startIfNeeded(model: ModelDescriptor) async throws
    /// `GET /health`, short timeout — `false` whenever `state` isn't `.ready`.
    func healthCheck() async -> Bool
    /// Manual retry: recovers from `.failed`, or forces a fresh launch from any other
    /// state. Bypasses any pending backoff wait (docs/05-lld.md §5.1: `Failed -->
    /// Launching: manual retry`).
    func restart() async
    /// Terminate the process (if any) and settle in `.stopped`. Reachable from any state.
    func stop() async
    /// Swap the running model (tier change / Model Residency unload+reload, LLD §5.4).
    /// Minimal/stub-correct here (stop, then relaunch with the new model) — full
    /// tier-swap semantics (a dedicated in-flight state, Session Context preservation)
    /// are Phase 6's job.
    func swapModel(to model: ModelDescriptor) async throws
    /// Signal that the Sidecar was just used (Phase 6; LLD §5.4). Resets the
    /// idle-unload timer so an 8GB-tier Sidecar stays resident while active.
    func recordActivity()
}
