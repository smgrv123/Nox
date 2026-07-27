import Foundation

/// A persistent, actionable fix-it for a permission that isn't granted (User Story 26):
/// a plain-language hint explaining what's lost and how to fix it, plus the exact
/// System Settings **deep-link**. A granted permission produces no advice.
///
/// The `(permission, status) → advice?` mapping is pure and exhaustively tested; the
/// menubar / Settings / (later) overlay just render whatever `make` returns.
public struct PermissionAdvice: Equatable, Sendable {
    /// The permission this advice is about.
    public let permission: Permission
    /// The status that produced the advice (drives the wording).
    public let status: PermissionStatus
    /// The actionable, human-readable fix-it hint.
    public let hint: String
    /// Deep-link to the exact System Settings pane to grant the permission.
    public let deepLink: URL

    /// Build the fix-it for a permission at a given status, or `nil` when the
    /// permission is granted (nothing to fix). This is the status → hint/deep-link
    /// mapping the module exists to own.
    public static func make(for permission: Permission, status: PermissionStatus) -> PermissionAdvice? {
        guard let hint = hint(for: permission, status: status) else { return nil }
        return PermissionAdvice(
            permission: permission, status: status, hint: hint, deepLink: permission.settingsDeepLink)
    }

    /// The consequence + fix wording. `nil` for a granted permission.
    private static func hint(for permission: Permission, status: PermissionStatus) -> String? {
        switch status {
        case .granted:
            return nil
        case .denied, .notDetermined:
            return "\(permission.deniedConsequence) Open \(permission.settingsPaneName) and turn Aide on."
        case .restricted:
            return "\(permission.deniedConsequence) It's restricted by a system policy "
                + "(e.g. MDM or Screen Time); ask your administrator, then check \(permission.settingsPaneName)."
        }
    }
}
