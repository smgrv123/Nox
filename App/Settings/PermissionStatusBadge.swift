import Permissions
import SwiftUI

/// The shared `PermissionStatus` → icon/color mapping (Standards #4): both the
/// Permissions Settings pane (`PermissionsPane`) and the onboarding permission step
/// (`OnboardingPermissionStep`) render a badge per status, diverging only in label
/// copy — this is that one source, with the label text parameterized per call site.
struct PermissionStatusBadge: View {
    let status: PermissionStatus

    /// Label copy per status, defaulted to `PermissionsPane`'s wording.
    /// `OnboardingPermissionStep` overrides `denied`/`notDetermined`/`restricted`
    /// with its own, more encouraging phrasing.
    var granted = "Granted"
    var denied = "Denied"
    var notDetermined = "Not Determined"
    var restricted = "Restricted"

    var body: some View {
        switch status {
        case .granted:
            Label(granted, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .denied:
            Label(denied, systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
        case .notDetermined:
            Label(notDetermined, systemImage: "questionmark.circle")
                .foregroundStyle(.secondary)
        case .restricted:
            Label(restricted, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }
}
