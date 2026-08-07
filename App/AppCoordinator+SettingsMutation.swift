import Configuration
import Foundation
import Hotkeys
import Overlay
import Persistence

/// `AppCoordinator`'s persisted settings mutations (PHASE 8/9; User Stories 8, 13,
/// 14, 29, 30), split out of the coordinator's primary declaration so no single
/// file/type grows unwieldy. These are the sanctioned way to change `settings`: each
/// goes through the `updateSettings(_:)` funnel (`AppCoordinator.swift`) — which
/// publishes for the menubar/panes and atomically saves through `persistSettings()`
/// — then applies any live side-effect.
extension AppCoordinator {

    /// Set the audio-cue-on-listen preference (User Story 8) and persist it. Publishing
    /// `settings` re-renders the menubar; the atomic save makes the change survive a
    /// relaunch. A no-op if the value is unchanged.
    func setAudioCueOnListen(_ enabled: Bool) {
        guard settings.indicators.audioCueOnListen != enabled else { return }
        updateSettings { $0.indicators.audioCueOnListen = enabled }
    }

    /// Set the audio-cue-on-processing preference (User Story 8) and persist it.
    /// Mirrors `setAudioCueOnListen`; `VoiceSessionCoordinator`'s `playProcessingCue`
    /// sink (wired in `AppCoordinator.swift`) reads this on every accepted "PTT up".
    func setAudioCueOnProcessing(_ enabled: Bool) {
        guard settings.indicators.audioCueOnProcessing != enabled else { return }
        updateSettings { $0.indicators.audioCueOnProcessing = enabled }
    }

    /// Set the Overlay's screen position (PHASE 9; User Stories 29, 30) and persist
    /// it. Applies live to `overlay` so the **next** time it shows — no relaunch —
    /// it's already at the new anchor.
    func setOverlayPosition(_ position: Settings.OverlayPosition) {
        guard settings.indicators.overlayPosition != position else { return }
        updateSettings { $0.indicators.overlayPosition = position }
        overlay.applyIndicatorSettings(settings.indicators)
    }

    /// Set whether the Overlay shows the Local/Cloud indicator badge (PHASE 9; User
    /// Stories 29, 30) and persist it. Applies live to `overlay`, same as
    /// `setOverlayPosition`.
    func setShowLocalCloudIndicator(_ show: Bool) {
        guard settings.indicators.showLocalCloudIndicator != show else { return }
        updateSettings { $0.indicators.showLocalCloudIndicator = show }
        overlay.applyIndicatorSettings(settings.indicators)
    }

    // MARK: - Hotkey rebinding (PHASE 9; User Stories 13, 14, 29)

    /// Rebind one semantic hotkey to a freshly captured chord (already validated by
    /// `HotkeyChordValidation` in the rebind UI), persist it, and — the acceptance-
    /// critical part — make it take effect **immediately, without relaunch**.
    ///
    /// `HotkeyManager.start(binder:)` assigns its `binder` before the idempotent
    /// tap-install guard, so calling it again with a freshly built `HotkeyBinder`
    /// swaps the active binding live without recreating the `CGEventTap` (see its doc
    /// comment) — that's the whole mechanism.
    func rebindHotkey(_ hotkey: SemanticHotkey, to binding: Settings.HotkeyBinding) {
        let current = hotkey == .command ? settings.hotkeys.commandMode : settings.hotkeys.dictationMode
        guard current != binding else { return }

        updateSettings { settings in
            switch hotkey {
            case .command: settings.hotkeys.commandMode = binding
            case .dictation: settings.hotkeys.dictationMode = binding
            }
        }
        hotkeys.start(binder: HotkeyBinder(hotkeys: settings.hotkeys))
    }

    /// Atomically write the current settings. A failure is logged (User Story 38), not
    /// fatal — the in-memory value still reflects the user's choice for this session.
    /// Called by `updateSettings(_:)` (`AppCoordinator.swift`) after every mutation —
    /// the sole path every setter here and every write in
    /// `AppCoordinator+Onboarding.swift` now goes through.
    func persistSettings() {
        guard let settingsStore else { return }
        do {
            try settingsStore.save(settings)
        } catch {
            appLog?.log("Failed to persist settings: \(error.localizedDescription)", level: .error)
        }
    }
}
