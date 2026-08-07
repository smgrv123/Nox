import SwiftUI

/// A single Settings pane descriptor — the registration unit of the Settings
/// framework (Phase 8; User Story 28). A pillar adds a pane by appending one
/// `SettingsPane` value to the list `SettingsRootView` renders; the host never
/// needs to change, so registering a pane is data, not surgery on the host view.
struct SettingsPane: Identifiable {
    /// Stable identity, also used as the `TabView` tag so SwiftUI can track
    /// which pane is selected across re-renders.
    let id: String

    /// The tab's label.
    let title: String

    /// SF Symbol shown next to the label.
    let systemImage: String

    /// Builds the pane's content. Type-erased so panes with unrelated concrete
    /// view types can live side by side in one array.
    let content: () -> AnyView

    init(id: String, title: String, systemImage: String, @ViewBuilder content: @escaping () -> some View) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.content = { AnyView(content()) }
    }
}
