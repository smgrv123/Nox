import Foundation
import ModelProvisioning

/// The injection seam between the pure lifecycle engine (`SidecarLifecycleController`)
/// and the real `llama-server` `Process`/loopback-HTTP mechanics (plan Phase 2's
/// "Architectural decisions": the real `Process` spawn lives in the App/-layer
/// `SidecarManager`, absorbed from Phase 1's spike). The engine only ever talks to
/// this protocol, never `Process`/`URLSession` directly — which is what lets
/// `SidecarLifecycleControllerTests` drive the full `stopped -> launching -> ready ->
/// unhealthy -> failed` state machine against an injected fake, with **no real
/// process and no real network** (plan Phase 2's acceptance criteria).
public protocol SidecarProcessSource: Sendable {
    /// Launch the sidecar for `model` and return the bound loopback port. Does **not**
    /// wait for readiness — that's `checkHealth`'s job, polled by the engine.
    func launch(model: ModelDescriptor) async throws -> Int

    /// `GET /health` (or equivalent) against `port`, short timeout. `false` covers
    /// both "responded unhealthy" and "connection refused" (docs/05-lld.md §5.1) —
    /// the engine doesn't need to distinguish them.
    func checkHealth(port: Int) async -> Bool

    /// Kill the current process, if one is running. Idempotent — safe to call when
    /// nothing is running, and safe to call more than once.
    func terminate() async
}
