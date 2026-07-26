import Foundation

/// The prompt-free permission gate (P1 Phase 7; User Stories 25, 26, 27).
///
/// It answers three questions over a snapshot of statuses:
/// - **status(for:)** — the current grant state of a permission (read prompt-free);
/// - **advice(for:)** — the fix-it hint + deep-link when it's not granted (User Story 26);
/// - **isEnabled(_:) / disabledFeatures()** — graceful degradation: which features a
///   denied permission takes down, and only those (User Story 25).
///
/// Statuses are **injected** (a `read` closure), so the gate is pure and deterministic:
/// tests pass a fixed snapshot; the app passes `SystemPermissionReader.liveStatus`, the
/// thin effectful shell that performs the real TCC queries without ever prompting.
public struct PermissionGate {

    private let read: (Permission) -> PermissionStatus

    /// - Parameter read: yields the current, prompt-free status of a permission.
    ///   The app injects the live TCC reader; tests inject a fixed snapshot.
    public init(read: @escaping (Permission) -> PermissionStatus) {
        self.read = read
    }

    /// Convenience for a fixed snapshot. A permission absent from `statuses` fails safe
    /// to `.notDetermined` (its features stay disabled) rather than assuming a grant.
    public init(statuses: [Permission: PermissionStatus]) {
        self.read = { statuses[$0] ?? .notDetermined }
    }

    /// The current status of a permission (prompt-free — reading never asks the user).
    public func status(for permission: Permission) -> PermissionStatus {
        read(permission)
    }

    /// The fix-it (hint + deep-link) for a permission that isn't granted, or `nil` when
    /// it is granted. Re-granting flips this back to `nil` — the recovery path.
    public func advice(for permission: Permission) -> PermissionAdvice? {
        PermissionAdvice.make(for: permission, status: read(permission))
    }

    /// Whether a feature may run: true only when its single gating permission is granted.
    public func isEnabled(_ feature: Feature) -> Bool {
        read(feature.requiredPermission).isUsable
    }

    /// Every feature whose gating permission isn't granted — the exact set disabled by
    /// the current permission state, nothing more (User Story 25).
    public func disabledFeatures() -> Set<Feature> {
        Set(Feature.allCases.filter { !isEnabled($0) })
    }

    /// Permissions that are not granted, in canonical `Permission.allCases` order —
    /// the ones needing a fix-it.
    public func degradedPermissions() -> [Permission] {
        Permission.allCases.filter { !read($0).isUsable }
    }

    /// Fix-its for every non-granted permission, in canonical order — the persistent,
    /// actionable list a Settings pane (or the menubar) renders (User Story 26).
    public func fixIts() -> [PermissionAdvice] {
        Permission.allCases.compactMap { advice(for: $0) }
    }
}
