import Configuration
import SwiftUI

/// Dictation Settings (P5a Phase 4): default tone and cleanup toggle. The per-app
/// AX/paste insertion override list this pane once showed is gone — AX insertion was
/// removed (dictation always pastes now), so there is nothing left to override.
struct DictationPane: View {
    @ObservedObject var coordinator: AppCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Dictation")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                Text("Default Tone").font(.subheadline.bold())
                Picker(
                    "Default Tone",
                    selection: Binding(
                        get: { coordinator.settings.tone.defaultPreset },
                        set: { coordinator.setDefaultTonePreset($0) })
                ) {
                    // `Configuration.Settings` is spelled out because this file also
                    // imports SwiftUI, whose own `Settings` scene type would otherwise
                    // make the bare name ambiguous.
                    ForEach(Configuration.Settings.TonePreset.allCases, id: \.self) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }

            Divider()

            Toggle(
                "Clean up dictated text",
                isOn: Binding(
                    get: { coordinator.settings.dictation.cleanupEnabled },
                    set: { coordinator.setDictationCleanupEnabled($0) }))

            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension Configuration.Settings.TonePreset {
    fileprivate var displayName: String {
        switch self {
        case .asIs: return "As-is"
        case .professional: return "Professional"
        case .casual: return "Casual"
        case .concise: return "Concise"
        }
    }
}
