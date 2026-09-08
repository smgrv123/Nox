import Configuration
import SwiftUI

/// Dictation Settings (P5a Phase 4): default tone, cleanup toggle, and a
/// read-only list of per-app insertion overrides. Override *learning* is Phase 5;
/// this pane only displays whatever `text_insertion.app_overrides` already holds.
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

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("App Overrides").font(.subheadline.bold())
                appOverridesList
            }

            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var appOverridesList: some View {
        let overrides = coordinator.settings.textInsertion.appOverrides
        if overrides.isEmpty {
            Text("No app overrides yet")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            ForEach(overrides.keys.sorted(), id: \.self) { bundleID in
                HStack {
                    Text(bundleID)
                    Spacer()
                    Text(Self.overrideLabel(overrides[bundleID]))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private static func overrideLabel(_ override: Configuration.Settings.InsertionOverride?) -> String {
        switch override {
        case .ax: return "AX"
        case .paste: return "Paste"
        case nil: return ""
        }
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
