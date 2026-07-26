import AideCore
import AppKit
import AppLifecycle
import Configuration
import Hotkeys
import Permissions
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

    /// The last lifecycle status the hotkey tap reported — the text shown when no
    /// hotkey is held. Cached so a hold's key-up restores it verbatim rather than
    /// re-authoring a second, drift-prone copy of the "ready" string. Main-actor-only.
    private var idleStatus = "Starting…"

    /// The loaded user preferences (docs/05-lld.md §2.5). Main-actor-owned state the
    /// menubar reads; mutated only through the setters below, which also persist.
    /// Defaults are in place before `applicationDidFinishLaunching()` loads the file,
    /// so the UI is always safe to render.
    @Published private(set) var settings: Settings = .defaults

    /// P7 (User Stories 15, 26): the persistent, actionable fix-it for the Accessibility
    /// grant that the hotkey path needs. `nil` when granted (nothing to fix). The menubar
    /// renders `hint` + a deep-link button; re-granting clears it (recovery).
    @Published private(set) var accessibilityFixIt: PermissionAdvice?

    private let hotkeys = HotkeyManager()
    private let singleInstance = SingleInstanceGuard()

    /// The non-activating Overlay panel + its state machine (Phase 4; User Stories 5,
    /// 6, 7, 10). `AppCoordinator` owns it; Phase 6 wires the hotkey → Overlay loop
    /// through `overlay.send(_:)`. `internal` so the menubar's temporary debug items
    /// can drive it (see `MenubarMenu`).
    let overlay = OverlayController()
    private let logger = Logger(subsystem: Build.bundleIdentifier, category: "Lifecycle")

    /// Prompt-free permission detection for all four permissions (User Story 27). The
    /// pure hint/deep-link/degradation logic lives in `PermissionGate`; the injected
    /// `SystemPermissionReader` is the thin effectful TCC shell. Later phases (the
    /// Settings Permissions pane) reuse this same gate.
    private let permissionGate = PermissionGate(read: SystemPermissionReader().liveStatus)

    /// The separate, focus-taking confirmation window (PHASE 11; docs/04-hld.md
    /// §13.3). Distinct from the non-activating overlay — see `ConfirmationModal`.
    private let confirmationModal = ConfirmationModal()

    /// Sleep/wake observer tokens (PHASE 11; User Story 37), torn down in `deinit`.
    private var sleepWakeObservers: [NSObjectProtocol] = []

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
        startHotkeys()
        installSleepWakeObserver()
    }

    /// Install the global push-to-talk tap and route its two callbacks to the menubar
    /// status. Called after `setUpStorage()` so the binder reflects the user's loaded
    /// `settings.hotkeys`, not a placeholder (User Stories 11, 12). Both callbacks are
    /// delivered on the main actor by `HotkeyManager`; the `Task { @MainActor }` hop
    /// keeps the `@Published` mutation isolated and matches the rest of this type.
    private func startHotkeys() {
        hotkeys.onStatus = { [weak self] status in
            Task { @MainActor in self?.showHotkeyStatus(status) }
        }
        hotkeys.onActivation = { [weak self] activation in
            Task { @MainActor in self?.reflectHold(activation) }
        }
        // P7: surface (or clear) the Accessibility fix-it as the tap install
        // succeeds/fails (User Stories 15, 26). Delivered on the main actor.
        hotkeys.onAccessibilityStatus = { [weak self] advice in
            Task { @MainActor in self?.accessibilityFixIt = advice }
        }
        hotkeys.start(binder: HotkeyBinder(hotkeys: settings.hotkeys))
    }

    /// A lifecycle status from the tap (installed-and-ready, or the Accessibility-denied
    /// message — User Story 15). It doubles as the "idle" text a hold returns to, so it
    /// is cached in `idleStatus`.
    @MainActor
    private func showHotkeyStatus(_ status: String) {
        idleStatus = status
        statusText = status
    }

    /// Reflect a push-to-talk hold in the menubar: down → a listening state that names
    /// the mode (command vs dictation, so the two hotkeys are visibly distinguished —
    /// User Story 12); up → back to the idle status (User Story 11).
    @MainActor
    private func reflectHold(_ activation: HotkeyActivation) {
        switch activation.phase {
        case .down:
            statusText = "🎙️ Listening — \(activation.hotkey.displayName)"
        case .up:
            statusText = idleStatus
        }
    }

    /// Observe system sleep/wake so the app resumes in a sane state (PHASE 11; User
    /// Stories 37, 38). Both edges are recorded to `app.log` (a human-readable state,
    /// never silence); on wake the hotkey tap — which macOS can disable across sleep —
    /// is re-asserted so Push-to-Talk keeps working. Notifications arrive on `.main`.
    private func installSleepWakeObserver() {
        let center = NSWorkspace.shared.notificationCenter
        let sleep = center.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.appLog?.log("System is going to sleep.", level: .notice)
        }
        let wake = center.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.appLog?.log("System woke from sleep — revalidating hotkey capture.", level: .notice)
            self?.hotkeys.revalidate()
        }
        sleepWakeObservers = [sleep, wake]
    }

    deinit {
        let center = NSWorkspace.shared.notificationCenter
        for observer in sleepWakeObservers { center.removeObserver(observer) }
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

    // MARK: - Permission fix-it (P7; User Stories 15, 26, 27)

    /// Open the exact System Settings pane carried by a fix-it (the deep-link comes from
    /// `PermissionGate`, the single source of truth — docs/05-lld.md §8).
    func openFixIt(_ advice: PermissionAdvice) {
        NSWorkspace.shared.open(advice.deepLink)
    }

    /// Re-read the Accessibility grant **prompt-free** (User Story 27) after the user
    /// returns from System Settings. If it's now granted, re-attempt the hotkey tap —
    /// which installs it and clears the fix-it (recovery). Otherwise refresh the hint so
    /// it stays visible and actionable.
    ///
    /// SEAM: the Overlay (a sibling phase, not in this worktree) will attach its own
    /// fix-it affordance to the same `accessibilityFixIt` / `openFixIt` / `recheck` API —
    /// no overlay code is referenced here so the phases stay independent.
    func recheckAccessibility() {
        if permissionGate.status(for: .accessibility).isUsable {
            hotkeys.retry()
        } else {
            accessibilityFixIt = permissionGate.advice(for: .accessibility)
        }
    }

    // MARK: - Wipe all history (PHASE 11; User Story 34)

    /// Ask the user to confirm a history wipe, routed through the focus-taking
    /// `ConfirmationModal` (the real trigger that also exercises the modal infra).
    /// Nothing is deleted until the user takes the deliberate destructive action.
    func requestWipeAllHistory() {
        let content = ConfirmationModal.Content(
            title: "Wipe all history?",
            message:
                "This permanently deletes your transcripts, command history, and script logs. "
                + "Your settings, scripts, and dictionary are kept.",
            confirmTitle: "Wipe History")
        confirmationModal.present(content) { [weak self] in
            self?.performWipe()
        }
    }

    /// Run the scoped wipe against the resolved storage tree and surface the outcome
    /// as a human-readable status + `app.log` line (User Story 38 — never silent).
    /// The *scope* (what's deleted vs preserved) is the tested `HistoryWipe` policy.
    private func performWipe() {
        guard let storage else {
            appLog?.log("Wipe requested but storage is unavailable.", level: .error)
            statusText = "Couldn't wipe history — storage unavailable"
            return
        }
        do {
            let removed = try HistoryWipe(layout: storage).perform()
            appLog?.log("Wiped history: removed \(removed.count) file(s).", level: .notice)
            statusText = "History wiped (\(removed.count) file\(removed.count == 1 ? "" : "s"))"
        } catch {
            appLog?.log("Wipe failed: \(error.localizedDescription)", level: .error)
            statusText = "Couldn't wipe history — see app.log"
        }
    }
}
