import Permissions
import SwiftUI

/// The Permissions pane (Phase 8; User Stories 31, 32): lists each of the four
/// permissions with its live, prompt-free status and — when it isn't granted —
/// a fix-it hint plus a button that deep-links into the exact System Settings
/// pane. Reads through `coordinator.permissionGate` — the one `PermissionGate`
/// `AppCoordinator` owns (docs/05-lld.md §8) — rather than constructing its own,
/// so every surface that reads permission status shares a single source.
struct PermissionsPane: View {
    @ObservedObject var coordinator: AppCoordinator

    @Environment(\.openURL) private var openURL

    /// The last-read status per permission. Populated on `.onAppear` and by the
    /// "Re-check" button so a grant made in System Settings while this pane is
    /// open — or before it — is reflected without relaunching the app. Reading
    /// is always prompt-free (User Story 27's contract extends to this pane).
    @State private var statuses: [Permission: PermissionStatus] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            List(Permission.allCases, id: \.self) { permission in
                row(for: permission)
            }
            .listStyle(.inset)

            Divider()

            HStack {
                Spacer()
                Button("Re-check") { refresh() }
            }
            .padding()
        }
        .onAppear { refresh() }
    }

    @ViewBuilder
    private func row(for permission: Permission) -> some View {
        let status = statuses[permission] ?? .notDetermined
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(permission.displayName)
                    .font(.headline)
                Spacer()
                PermissionStatusBadge(status: status)
            }
            if let advice = coordinator.permissionGate.advice(for: permission) {
                Text(advice.hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Open \(permission.displayName) Settings…") {
                    openURL(advice.deepLink)
                }
                .font(.caption)
            }
        }
        .padding(.vertical, 4)
    }

    /// Re-read every permission's status, prompt-free, from `SystemPermissionReader`.
    /// Also re-runs the Input Monitoring recheck so a grant made in System Settings
    /// while this pane is open reinstalls the hotkey tap and clears the menubar
    /// fix-it, not just this pane's own status row.
    private func refresh() {
        coordinator.recheckInputMonitoring()
        statuses = Dictionary(
            uniqueKeysWithValues: Permission.allCases.map { ($0, coordinator.permissionGate.status(for: $0)) })
    }
}
