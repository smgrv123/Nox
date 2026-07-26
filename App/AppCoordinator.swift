import AideCore
import AppKit
import AppLifecycle
import Configuration
import Persistence
import os

/// Owns Aide's app lifecycle: single-instance enforcement at launch, the
/// app-lifetime singletons (currently just the hotkey tap), and the status string
/// the menubar renders. `AppDelegate` delegates lifecycle ownership here rather
/// than holding everything ad hoc (specs/P1 §"AppCoordinator"; User Stories 3, 4, 36).
///
/// Phase 1 scope: the menubar shell + single-instance guarantee. The voice-session
/// seam, sleep/wake handling, and richer status arrive in later P1 phases. The
/// effectful `NSRunningApplication` lookup lives here; the *decision* is the pure,
/// tested `SingleInstanceGuard`.
final class AppCoordinator: ObservableObject {

    /// Human-readable status surfaced in the menubar menu (User Stories 3, 10).
    @Published private(set) var statusText = "Starting…"

    /// The loaded user preferences (docs/05-lld.md §2.5). Main-actor-owned state the
    /// menubar reads; mutated only through the setters below, which also persist.
    /// Defaults are in place before `applicationDidFinishLaunching()` loads the file,
    /// so the UI is always safe to render.
    @Published private(set) var settings: Settings = .defaults

    private let hotkeys = HotkeyManager()
    private let singleInstance = SingleInstanceGuard()

    /// The non-activating Overlay panel + its state machine (Phase 4; User Stories 5,
    /// 6, 7, 10). `AppCoordinator` owns it; Phase 6 wires the hotkey → Overlay loop
    /// through `overlay.send(_:)`. `internal` so the menubar's temporary debug items
    /// can drive it (see `MenubarMenu`).
    let overlay = OverlayController()
    private let logger = Logger(subsystem: Build.bundleIdentifier, category: "Lifecycle")

    /// The resolved Application Support layout and its plain-text log, populated on
    /// first launch (User Stories 33, 35). Later P1 phases (settings, history, wipe)
    /// read their paths from `storage`.
    private(set) var storage: StorageLayout?
    private(set) var appLog: AppLog?

    /// The settings load/save façade, bound to `storage.settingsFile` once storage is
    /// resolved. `nil` only if storage set-up failed (settings then stay at defaults).
    private var settingsStore: SettingsStore?

    /// Set when this launch is a duplicate that is standing down — stops the
    /// newcomer from installing its hotkey tap on the way out.
    private var isDuplicateInstance = false

    /// Enforced as early as possible: if another copy is already running, this
    /// newcomer yields immediately so two instances never fight over the mic,
    /// hotkeys, or (later) the sidecar port (User Story 36).
    func applicationWillFinishLaunching() {
        let bundleID = Bundle.main.bundleIdentifier ?? Build.bundleIdentifier
        let snapshot = NSWorkspace.shared.runningApplications.map {
            RunningInstance(bundleIdentifier: $0.bundleIdentifier, processIdentifier: $0.processIdentifier)
        }

        guard
            singleInstance.isDuplicate(
                ownBundleIdentifier: bundleID,
                ownProcessIdentifier: ProcessInfo.processInfo.processIdentifier,
                runningInstances: snapshot)
        else { return }

        isDuplicateInstance = true
        logger.notice(
            "Another instance of \(bundleID, privacy: .public) is already running — standing this duplicate down.")
        NSApp.terminate(nil)
    }

    /// Start app-lifetime services once the launch is confirmed to be the sole
    /// instance (User Stories 3, 11).
    func applicationDidFinishLaunching() {
        guard !isDuplicateInstance else { return }
        setUpStorage()
        hotkeys.onStatusChange = { [weak self] status in
            Task { @MainActor in self?.statusText = status }
        }
        hotkeys.start()
    }

    /// Create the Application Support tree (idempotent — only what's missing) and
    /// open `app.log`, then record a startup line (User Stories 33, 35). The pure
    /// path/tree logic lives in `StorageLayout`; this is the thin effectful call.
    /// A failure here is non-fatal: it's logged to the unified system log (there is
    /// no `app.log` to write to yet) and the app keeps running.
    private func setUpStorage() {
        do {
            let layout = try StorageLayout.applicationSupport()
            try layout.createTree()
            let log = AppLog(fileURL: layout.appLogFile)
            log.log("Aide \(Build.version) launched (pid \(ProcessInfo.processInfo.processIdentifier)).")
            storage = layout
            appLog = log
            loadSettings(from: layout, log: log)
        } catch {
            logger.error(
                "Failed to create the storage tree: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Bind the settings store to the on-disk document and load it (User Stories 33,
    /// 35; docs/05-lld.md §2.5). Non-nominal outcomes (missing / migrated / recovered)
    /// are surfaced to `app.log` rather than swallowed (User Story 38); the load
    /// itself never fails — it always yields a usable `Settings`.
    private func loadSettings(from layout: StorageLayout, log: AppLog) {
        let store = SettingsStore(
            fileURL: layout.settingsFile,
            signal: { signal in
                switch signal {
                case .missing:
                    log.log("No settings file yet; starting from defaults.")
                case .migrated(let from):
                    log.log(
                        "Migrated settings from schema v\(from) to v\(Settings.currentSchemaVersion).",
                        level: .notice)
                case .recovered(let backupURL):
                    let backedUp = backupURL.map { " (corrupt file backed up to \($0.lastPathComponent))" } ?? ""
                    log.log("Settings file was unreadable; restored defaults\(backedUp).", level: .warning)
                }
            })
        settingsStore = store
        settings = store.load()
    }

    // MARK: - Settings mutation (persisted)

    /// Set the audio-cue-on-listen preference (User Story 8) and persist it. Publishing
    /// `settings` re-renders the menubar; the atomic save makes the change survive a
    /// relaunch. A no-op if the value is unchanged.
    func setAudioCueOnListen(_ enabled: Bool) {
        guard settings.indicators.audioCueOnListen != enabled else { return }
        settings.indicators.audioCueOnListen = enabled
        persistSettings()
    }

    /// Atomically write the current settings. A failure is logged (User Story 38), not
    /// fatal — the in-memory value still reflects the user's choice for this session.
    private func persistSettings() {
        guard let settingsStore else { return }
        do {
            try settingsStore.save(settings)
        } catch {
            appLog?.log("Failed to persist settings: \(error.localizedDescription)", level: .error)
        }
    }

    /// Deep-link to the exact System Settings pane for the Accessibility grant.
    /// (Onboarding drives this properly in a later P1 phase — docs/04-hld.md §14;
    /// surfaced here so the tracer-bullet hotkey status stays actionable.)
    static func openAccessibilitySettings() {
        let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}
