import Foundation

/// A snapshot of one running application, reduced to the two fields the
/// single-instance decision needs.
///
/// This is the **injected** input that keeps the decision pure and headlessly
/// testable: the effectful `NSRunningApplication` enumeration lives in the app
/// shell (`AppCoordinator`), which maps each running app into one of these before
/// asking `SingleInstanceGuard` for a verdict.
public struct RunningInstance: Equatable, Sendable {
    /// The app's bundle identifier, or `nil` for processes that have none.
    public let bundleIdentifier: String?
    /// The app's process identifier (PID).
    public let processIdentifier: Int32

    public init(bundleIdentifier: String?, processIdentifier: Int32) {
        self.bundleIdentifier = bundleIdentifier
        self.processIdentifier = processIdentifier
    }
}

/// Pure, deterministic decision for single-instance enforcement (User Story 36).
///
/// Two copies of Aide must never run at once — they would fight over the mic,
/// the global hotkeys, and (later) the sidecar's loopback port. The *decision* —
/// "given everything currently running, am I a duplicate that should stand down?"
/// — is pure and unit-tested headlessly; the effectful process lookup and the
/// actual termination are a thin shell in `AppCoordinator` (specs/P1 §"Concurrency
/// rules", §"AppCoordinator").
public struct SingleInstanceGuard: Sendable {

    public init() {}

    /// Decide whether *this* process is a duplicate newcomer that should abort.
    ///
    /// Another instance is any running process that shares our bundle identifier
    /// but carries a different PID. If one exists we are the newcomer and must
    /// yield to it. The original instance ran this same check at *its* launch —
    /// before we existed, so it saw none — which is why exactly one survives even
    /// when a second copy is started.
    ///
    /// - Parameters:
    ///   - ownBundleIdentifier: this process's bundle identifier.
    ///   - ownProcessIdentifier: this process's PID (used to exclude ourselves).
    ///   - runningInstances: a snapshot of every running app; may include self.
    /// - Returns: `true` iff another instance of the same app is already running.
    public func isDuplicate(
        ownBundleIdentifier: String,
        ownProcessIdentifier: Int32,
        runningInstances: [RunningInstance]
    ) -> Bool {
        runningInstances.contains { instance in
            instance.bundleIdentifier == ownBundleIdentifier
                && instance.processIdentifier != ownProcessIdentifier
        }
    }
}
