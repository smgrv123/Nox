import Configuration
import SwiftUI

/// The overlay/indicator options pane (Phase 9; User Stories 29, 30): the Overlay's
/// screen position, both audio-cue toggles, and whether the Local/Cloud indicator
/// badge is shown. Every control writes straight through an `AppCoordinator` setter,
/// which persists immediately and — for position/indicator visibility — applies live
/// to `OverlayController` so the Overlay's next show already reflects the change,
/// with no relaunch.
struct OverlayOptionsPane: View {
    @ObservedObject var coordinator: AppCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Overlay & Indicators")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                Text("Overlay Position").font(.subheadline.bold())
                Picker(
                    "Overlay Position",
                    selection: Binding(
                        get: { coordinator.settings.indicators.overlayPosition },
                        set: { coordinator.setOverlayPosition($0) })
                ) {
                    // `Configuration.Settings` is spelled out because this file also
                    // imports SwiftUI, whose own `Settings` scene type would otherwise
                    // make the bare name ambiguous.
                    ForEach(Configuration.Settings.OverlayPosition.allCases, id: \.self) { position in
                        Text(position.displayName).tag(position)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Audio Cues").font(.subheadline.bold())
                Toggle(
                    "Play a cue when listening starts",
                    isOn: Binding(
                        get: { coordinator.settings.indicators.audioCueOnListen },
                        set: { coordinator.setAudioCueOnListen($0) }))
                Toggle(
                    "Play a cue when processing starts",
                    isOn: Binding(
                        get: { coordinator.settings.indicators.audioCueOnProcessing },
                        set: { coordinator.setAudioCueOnProcessing($0) }))
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Indicator").font(.subheadline.bold())
                Toggle(
                    "Show the Local/Cloud indicator",
                    isOn: Binding(
                        get: { coordinator.settings.indicators.showLocalCloudIndicator },
                        set: { coordinator.setShowLocalCloudIndicator($0) }))
                Text(
                    "Shown on the Overlay while Aide is listening or working. Always reads "
                        + "LOCAL in this build — cloud escalation is a later pillar."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension Configuration.Settings.OverlayPosition {
    fileprivate var displayName: String {
        switch self {
        case .topCenter: return "Top Center"
        case .bottomCenter: return "Bottom Center"
        }
    }
}
