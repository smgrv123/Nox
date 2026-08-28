import AideCore
import AppKit
import AppLifecycle
import Configuration
import Hotkeys
import ModelProvisioning
import Onboarding
import Overlay
import Permissions
import Persistence
import STTVoiceSession
import SpeechToText
import VoiceSession
import WhisperSTTEngine
import os

/// Owns Aide's app lifecycle: single-instance enforcement at launch, the
/// app-lifetime singletons (currently just the hotkey tap), and the status string
/// the menubar renders. `AppDelegate` delegates lifecycle ownership here rather
/// than holding everything ad hoc (specs/P1 §"AppCoordinator"; User Stories 3, 4, 36).
///
/// This primary declaration holds lifecycle wiring + shared state; cohesive
/// concern-groups live in same-type extensions instead (settings mutation, onboarding,
/// model provisioning, the Sidecar) so no single file/type grows unwieldy.
final class AppCoordinator: ObservableObject {

    /// Human-readable status surfaced in the menubar menu (User Stories 3, 10).
    @Published private(set) var statusText = "Starting…"

    /// The last lifecycle status the hotkey tap reported — the text shown when no
    /// hotkey is held. Cached so a hold's key-up restores it verbatim rather than
    /// re-authoring a second, drift-prone copy of the "ready" string. Main-actor-only.
    private var idleStatus = "Starting…"

    /// The loaded user preferences (docs/05-lld.md §2.5). Main-actor-owned state the
    /// menubar reads; `private(set)` so no other App code can write it without also
    /// persisting it — the only way to change it is `updateSettings(_:)` below, which
    /// every setter in `AppCoordinator+SettingsMutation.swift` and every settings
    /// write in `AppCoordinator+Onboarding.swift` goes through. Defaults are in place
    /// before `applicationDidFinishLaunching()` loads the file, so the UI is always
    /// safe to render.
    @Published private(set) var settings: Settings = .defaults

    /// P7 (User Stories 15, 26): the persistent, actionable fix-it for the Input Monitoring
    /// grant that the hotkey path needs. `nil` when granted (nothing to fix). The menubar
    /// renders `hint` + a deep-link button; re-granting clears it (recovery).
    @Published private(set) var inputMonitoringFixIt: PermissionAdvice?

    /// PHASE 10 (User Stories 16–24): the pure first-run flow's current state, or
    /// `nil` when onboarding isn't showing (not yet started this launch, or already
    /// completed). `OnboardingWindow` observes this to know when to show/hide;
    /// `App/Onboarding/*` step views read `currentStep` to render. Every mutation
    /// goes through the `onboarding*` methods (`AppCoordinator+Onboarding.swift`),
    /// which also persist progress.
    @Published var onboardingFlow: OnboardingFlow?

    let hotkeys = HotkeyManager()
    private let singleInstance = SingleInstanceGuard()

    /// The non-activating Overlay panel + its state machine (Phase 4; User Stories 5,
    /// 6, 7, 10). `AppCoordinator` owns it; Phase 6 wires the hotkey → Overlay loop
    /// through `overlay.send(_:)`. `internal` so the menubar's temporary debug items
    /// can drive it (see `MenubarMenu`).
    let overlay = OverlayController()

    /// P2a Phase 3 (the seam paying off; User Stories 1, 6, 22): the **real** STT-backed
    /// `AideCore.VoiceSessionDriver`, swapped in for `MockVoiceSessionDriver` with no change
    /// to `VoiceSessionCoordinator`/Overlay. Constructing it opens nothing (mic opens only
    /// on a hold; model loads lazily; an absent model fails safe, not a crash). `lazy`, not
    /// `let` (Phase 5): the model path depends on `settings.sttModelTier`, not loaded yet at
    /// construction time — only once `setUpStorage()` runs. Mirrors `voiceSession` below.
    private lazy var voiceDriver = STTVoiceSessionDriver(
        engine: WhisperSTTEngine(modelURL: AppCoordinator.modelsDirectory.blobURL(for: resolvedSttModelDescriptor)),
        capture: AudioCapture(),
        preGate: SegmentPreGate(thresholds: .provisional))

    /// Progress/failure/ready state of the onboarding-triggered Whisper (`stt`) and
    /// Qwen (`llm`) downloads (Phase 5); `nil` until `confirmModelTier(_:)` starts each.
    @Published var sttModelProvisioningState: ModelProvisioner.State?
    @Published var llmModelProvisioningState: ModelProvisioner.State?

    /// The in-flight provisioning task, if any — cancelled/replaced on Retry.
    var sttModelProvisioningTask: Task<Void, Never>?

    /// Orchestrates hotkey → Overlay → `voiceDriver` → Overlay (docs/04-hld.md §13,
    /// docs/05-lld.md §10). `lazy` because its `emit` sink is `overlay.send` and its
    /// `playCue`/`presentText` sinks close over `self` — all only valid once this
    /// instance is fully initialized; first access is from `startHotkeys()`.
    private lazy var voiceSession = VoiceSessionCoordinator(
        driver: voiceDriver,
        emit: overlay.send,
        playCue: { [weak self] in self?.playListenCue() },
        scheduleAutoHide: { work in
            DispatchQueue.main.asyncAfter(deadline: .now() + AppCoordinator.resultDisplayDuration, execute: work)
        },
        presentText: { [weak self] transcript, result in
            self?.overlay.present(transcript: transcript, result: result?.summary)
        },
        playProcessingCue: { [weak self] in self?.playProcessingCue() },
        reportStatus: { [weak self] phase in self?.reflectVoiceSessionPhase(phase) })

    /// How long `.showingResult` stays on screen before Phase 6's loop auto-hides it.
    private static let resultDisplayDuration: TimeInterval = 2.5

    private let logger = Logger(subsystem: Build.bundleIdentifier, category: "Lifecycle")

    /// Prompt-free permission detection for all four permissions (User Story 27). The
    /// pure hint/deep-link/degradation logic lives in `PermissionGate`; the injected
    /// `SystemPermissionReader` is the thin effectful TCC shell. Later phases (the
    /// Settings Permissions pane) reuse this same gate.
    let permissionGate = PermissionGate(read: SystemPermissionReader().liveStatus)

    /// The separate, focus-taking confirmation window (PHASE 11; docs/04-hld.md
    /// §13.3). Distinct from the non-activating overlay — see `ConfirmationModal`.
    private let confirmationModal = ConfirmationModal()

    /// PHASE 10: the first-run walkthrough's window — an ordinary, focus-taking
    /// `NSWindow` (mirrors `ConfirmationModal`'s imperative AppKit mechanism, the
    /// established idiom for chrome outside the `MenuBarExtra`/Settings scenes).
    let onboardingWindow = OnboardingWindow()

    /// PHASE 10 (User Story 20): fires while a permission step is on screen so a
    /// grant made in System Settings is picked up even without the user switching
    /// focus back to Aide (which `applicationDidBecomeActive()` also covers,
    /// immediately). `nil` whenever onboarding isn't sitting on a permission step.
    var onboardingPermissionPollTimer: Timer?

    /// Sleep/wake observation (PHASE 11; User Story 37). `SleepWakeObserver` owns the
    /// `NSWorkspace` tokens and tears them down in its own `deinit` when this property
    /// is released — no explicit teardown needed here.
    private var sleepWakeObserver: SleepWakeObserver?

    /// The resolved Application Support layout and its plain-text log, populated on
    /// first launch (User Stories 33, 35). Later P1 phases (settings, history, wipe)
    /// read their paths from `storage`.
    private(set) var storage: StorageLayout?
    private(set) var appLog: AppLog?

    /// The settings load/save façade, bound to `storage.settingsFile` once storage is
    /// resolved. `nil` only if storage set-up failed (settings then stay at defaults).
    var settingsStore: SettingsStore?

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
            Task { @MainActor in
                self?.reflectHold(activation)
                // PHASE 6: alongside the menubar mirror above, drive the marquee
                // hotkey → Overlay → mock-driver loop (User Stories 2, 39, 40, 41).
                self?.voiceSession.handle(activation)
            }
        }
        // P7: surface (or clear) the Input Monitoring fix-it as the tap install
        // succeeds/fails (User Stories 15, 26). Delivered on the main actor.
        hotkeys.onInputMonitoringStatus = { [weak self] advice in
            Task { @MainActor in self?.inputMonitoringFixIt = advice }
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
    /// User Story 12); up → back to the idle status (User Story 11). This only covers
    /// the physical hold; `reflectVoiceSessionPhase(_:)` below picks up from here for
    /// Processing/ShowingResult, which have no corresponding hotkey edge.
    @MainActor
    private func reflectHold(_ activation: HotkeyActivation) {
        switch activation.phase {
        case .down:
            statusText = "🎙️ Listening — \(activation.hotkey.displayName)"
        case .up:
            statusText = idleStatus
        }
    }

    /// Mirror `VoiceSessionCoordinator`'s processing/result/idle phases into
    /// `statusText`, the single source the menubar reads (Phase 6 acceptance:
    /// "Menubar and overlay both reflect the state" — previously only `reflectHold`'s
    /// down/up edges touched `statusText`, so the menubar read idle throughout
    /// Processing/ShowingResult even though the Overlay had moved on). Wired as
    /// `voiceSession`'s `reportStatus` sink; `.listening` is never reported there —
    /// `reflectHold` above already owns that text.
    private func reflectVoiceSessionPhase(_ phase: VoiceSessionPhase) {
        switch phase {
        case .processing:
            statusText = "⏳ Processing…"
        case .result(let value):
            statusText = "✅ \(value.summary)"
        case .idle:
            statusText = idleStatus
        }
    }

    /// PHASE 6 (User Story 8): play the listen-start audio cue, gated on
    /// `settings.indicators.audioCueOnListen`. `VoiceSessionCoordinator` calls this on
    /// every accepted listen-start (fresh or PTT-restart) via the injected `playCue`
    /// sink — the gate lives here because `VoiceSession` has no visibility into
    /// `Configuration`'s `Settings`.
    private func playListenCue() {
        guard settings.indicators.audioCueOnListen else { return }
        NSSound(named: "Tink")?.play()
    }

    /// Play the processing-start audio cue, gated on
    /// `settings.indicators.audioCueOnProcessing` — mirrors `playListenCue()`.
    /// `VoiceSessionCoordinator` calls this on every accepted "PTT up" (processing
    /// begin) via the injected `playProcessingCue` sink, fixing the toggle that used
    /// to persist a preference nothing read.
    private func playProcessingCue() {
        guard settings.indicators.audioCueOnProcessing else { return }
        NSSound(named: "Tink")?.play()
    }

    /// Observe system sleep/wake so the app resumes in a sane state (PHASE 11; User
    /// Stories 37, 38). Both edges are recorded to `app.log` (a human-readable state,
    /// never silence); on wake the hotkey tap — which macOS can disable across sleep —
    /// is re-asserted so Push-to-Talk keeps working. Notifications arrive on `.main`
    /// (`SleepWakeObserver`'s contract).
    private func installSleepWakeObserver() {
        sleepWakeObserver = SleepWakeObserver(
            onSleep: { [weak self] in
                self?.appLog?.log("System is going to sleep.", level: .notice)
            },
            onWake: { [weak self] in
                self?.appLog?.log("System woke from sleep — revalidating hotkey capture.", level: .notice)
                self?.hotkeys.revalidate()
            })
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
        // PHASE 9 (User Stories 29, 30): the Overlay's position + indicator-visibility
        // must reflect the loaded settings from the very first show, not just after a
        // later change through the Settings pane.
        overlay.applyIndicatorSettings(settings.indicators)
        // PHASE 10 (User Stories 16, 24): present onboarding — fresh or resumed —
        // unless a prior launch already completed it.
        setUpOnboarding()
    }

    // MARK: - Settings mutation funnel (Standards: `settings` encapsulation)

    /// The sole sanctioned way any App code may mutate `settings`: apply `mutate` to
    /// it — which can write it because this method lives in the file that declares
    /// `private(set)` — then persist atomically via `persistSettings()`. Every setter
    /// in `AppCoordinator+SettingsMutation.swift` and every settings write in
    /// `AppCoordinator+Onboarding.swift` calls this instead of touching `settings`
    /// directly, so a change can never be published without also being saved.
    func updateSettings(_ mutate: (inout Settings) -> Void) {
        mutate(&settings)
        persistSettings()
    }

    // MARK: - Permission fix-it (P7; User Stories 15, 26, 27)

    /// Open the exact System Settings pane carried by a fix-it (the deep-link comes from
    /// `PermissionGate`, the single source of truth — docs/05-lld.md §8).
    func openFixIt(_ advice: PermissionAdvice) {
        NSWorkspace.shared.open(advice.deepLink)
    }

    /// Re-read the Input Monitoring grant **prompt-free** (User Story 27) after the user
    /// returns from System Settings. If it's now granted, re-attempt the hotkey tap —
    /// which installs it and clears the fix-it (recovery). Otherwise refresh the hint so
    /// it stays visible and actionable.
    func recheckInputMonitoring() {
        if permissionGate.status(for: .inputMonitoring).isUsable {
            hotkeys.retry()
        } else {
            inputMonitoringFixIt = permissionGate.advice(for: .inputMonitoring)
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
