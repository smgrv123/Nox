import AppKit
import CoreGraphics
import Hotkeys
import Permissions
import os

/// Global push-to-talk hotkey capture via `CGEventTap` (locked decision #4).
///
/// A session event tap is the mechanism used by comparable dictation tools: it yields
/// clean keyDown/keyUp pairs (needed to know when the user starts and stops holding)
/// and sees events from any foreground app. The tap is **active** (`.defaultTap`), not
/// listen-only: it consumes a bound push-to-talk chord — so the focused app never sees
/// it — the same way Raycast / Wispr Flow override their hotkeys, while every other key
/// passes through untouched. It requires the **Input Monitoring** permission
/// (`kTCCServiceListenEvent`); because an active tap can modify the event stream rather
/// than only observe it, `tapCreate` may now ALSO require **Accessibility** — a
/// permission Aide will separately need for Text Insertion (a later pillar)
/// (docs/04-hld.md §13, docs/05-lld.md §8).
///
/// This shell is deliberately thin: it installs the tap and forwards raw events to the
/// pure `HotkeyBinder` (the tested "settings → chords" + "event → semantic hotkey"
/// logic in the `Hotkeys` module). Concurrency rules it MUST honour (docs/05-lld.md
/// §10): the tap callback returns immediately, and all reaction to an event — the
/// binder lookup, the tiny held-hotkey state, and the UI-facing callbacks — happens on
/// the **main actor**.
final class HotkeyManager {

    /// The idle/ready status shown when no hotkey is held (single source so `start`
    /// and `revalidate` never drift).
    private static let readyStatus = "Ready — hold a hotkey to talk"
    /// The actionable Input-Monitoring-denied message (User Story 15): never fail silently.
    private static let inputMonitoringNeededStatus =
        "⚠️ Hotkeys need Input Monitoring access. Open the menu → “Open Input Monitoring Settings…”, "
        + "enable Aide, then relaunch."

    private let logger = Logger(subsystem: "com.aide.Aide", category: "Hotkey")
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    /// The dedicated background thread the tap's run loop lives on (docs/05-lld.md §10:
    /// "Hotkey CGEventTap callback runs on a dedicated run-loop thread"), never the main
    /// thread. Tracked (rather than `CFRunLoopGetCurrent()`) so `deinit` removes the
    /// source from the run loop that actually owns it, and so `start`/`retry` stay
    /// idempotent across the async window between spawning the thread and the tap
    /// finishing installation on it.
    private var tapThread: Thread?
    /// The tap's own `CFRunLoop`, captured on `tapThread` at install time. `deinit` uses
    /// this — never `CFRunLoopGetCurrent()` — to remove `runLoopSource` from the correct
    /// run loop.
    private var tapRunLoop: CFRunLoop?

    /// The chords to match against, derived from `Settings.hotkeys`. Set by `start`;
    /// read only on the main actor.
    private var binder: HotkeyBinder?

    /// The hotkey currently held down (push-to-talk). Main-actor-only state; lets us
    /// end the hold reliably even if the base key's modifier is released a hair before
    /// the key itself (so the tap reports the keyUp without the modifier bit).
    private var activeHotkey: SemanticHotkey?

    /// Semantic push-to-talk edge, delivered on the main actor. Later phases hook the
    /// real voice session here; today `AppCoordinator` turns it into menubar status.
    var onActivation: ((HotkeyActivation) -> Void)?

    /// Lifecycle / error status (installed, or Input-Monitoring-denied), on the main actor.
    var onStatus: ((String) -> Void)?

    /// P7 fix-it seam (User Stories 15, 26): reports the Input Monitoring grant state of the
    /// hotkey path. `nil` means the tap installed (granted / recovered); a non-nil
    /// `PermissionAdvice` carries the hint + exact-pane deep-link for the menubar (and,
    /// later, the overlay) to render instead of failing silently. Called on the main actor.
    var onInputMonitoringStatus: ((PermissionAdvice?) -> Void)?

    /// Whether the `CGEventTap` is REALLY installed — the single source of truth the rest
    /// of the App reads for "is the hotkey path live?". It must NOT be inferred from
    /// `IOHIDCheckAccess`, which can report granted while `tapCreate` is still denied
    /// (stale Input Monitoring grant after an ad-hoc dev rebuild). Read on the main actor.
    var isTapInstalled: Bool { eventTap != nil }

    /// Re-attempt the tap install (P7 recovery): after the user grants Input Monitoring in
    /// System Settings, this re-runs `start` with the binder already in hand, installing
    /// the tap and clearing the fix-it. A no-op if `start` was never called or the tap is
    /// already live.
    func retry() {
        guard let binder else { return }
        logger.info("retry(): re-attempting event tap install.")
        start(binder: binder)
    }

    /// Install the tap and begin matching against `binder`'s chords. Call after settings
    /// are loaded so the bindings reflect the user's configuration, not a placeholder.
    func start(binder: HotkeyBinder) {
        self.binder = binder
        // Idempotent: never stack a second tap (keeps `retry()` safe to call repeatedly).
        // `tapThread` is guarded too, not just `eventTap`, because installation now
        // finishes asynchronously on the dedicated thread below — without this, a
        // `retry()` landing inside that window (before `eventTap` is set) would spawn a
        // second thread racing to `tapCreate` a second tap.
        guard eventTap == nil, tapThread == nil else { return }

        // docs/05-lld.md §10: the active CGEventTap must live on a dedicated run-loop
        // thread, never the main run loop — a main-thread stall would otherwise freeze
        // system-wide input delivery for every app, not just Aide. `installEventTap()`
        // runs entirely on this thread, whose run loop it then pumps forever.
        let thread = Thread { [weak self] in
            self?.installEventTap()
        }
        thread.name = "com.aide.Aide.HotkeyEventTap"
        // Latency-sensitive: this thread must service the mach port promptly or macOS
        // will disable the tap (`tapDisabledByTimeout`), so it gets the same QoS the
        // main run loop would.
        thread.qualityOfService = .userInteractive
        tapThread = thread
        thread.start()
    }

    /// Runs entirely on the dedicated tap thread spawned by `start(binder:)`: creates
    /// the tap, wires its callback, attaches its run-loop source to *this* thread's run
    /// loop, then pumps that run loop forever so the tap keeps being serviced.
    private func installEventTap() {
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: CGEventMask(mask),
                callback: { _, type, event, refcon in
                    let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon!).takeUnretainedValue()
                    // Read the few primitive fields here (cheap) and hand off to the
                    // main actor. NOTHING heavy runs in the tap — it returns
                    // immediately, on the dedicated tap thread, never the main thread.
                    manager.enqueue(type: type, event: event)
                    // Consume (swallow) a bound push-to-talk chord — including its
                    // autorepeat keyDowns — so the focused app never sees it, the same
                    // way Raycast / Wispr Flow override their hotkeys.
                    if manager.isBoundPushToTalkChord(type: type, event: event) {
                        return nil
                    }
                    // Every other event (unbound keys, flagsChanged, tap-disabled
                    // notifications) passes through untouched.
                    return Unmanaged.passUnretained(event)
                },
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            )
        else {
            // Input Monitoring not granted: tapCreate fails. Surface an actionable
            // message — never fail silently (User Story 15) — and the P7 fix-it (hint
            // + exact-pane deep-link). The tap-create failure IS the
            // Input-Monitoring-denied signal for the hotkey path — though now that the
            // tap is active (`.defaultTap`, not listen-only), a `nil` here could ALSO
            // mean Accessibility is the missing grant; say so explicitly so this run's
            // logs point at the right pane. Hop back to the main actor: `onStatus`/
            // `onInputMonitoringStatus` and `tapThread` are main-actor-read state.
            logger.error(
                "Event tap creation failed — grant Input Monitoring; the active .defaultTap tap may also need Accessibility."
            )
            DispatchQueue.main.async {
                self.onStatus?(Self.inputMonitoringNeededStatus)
                self.onInputMonitoringStatus?(PermissionAdvice.make(for: .inputMonitoring, status: .denied))
                // Allow a future start()/retry() to try again.
                self.tapThread = nil
            }
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        let runLoop = CFRunLoopGetCurrent()
        CFRunLoopAddSource(runLoop, source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        DispatchQueue.main.async {
            self.eventTap = tap
            self.runLoopSource = source
            self.tapRunLoop = runLoop
            self.logger.info(
                "CGEvent.tapCreate ok; isTapInstalled=\(self.isTapInstalled, privacy: .public) (2 push-to-talk hotkeys bound)."
            )
            self.onStatus?(Self.readyStatus)
            // P7: tap installed ⇒ Input Monitoring is granted; clear any prior fix-it (recovery).
            self.onInputMonitoringStatus?(nil)
        }

        // Pump this thread's run loop forever so the tap's mach-port source keeps
        // being serviced; `deinit` removes the source and disables the tap, but does
        // not need to stop this loop for correctness (the process is exiting or the
        // manager outlives the app).
        CFRunLoopRun()
    }

    /// Re-assert the event tap after a system event that can silently disable it —
    /// notably sleep/wake (PHASE 11; User Story 37). macOS may disable a tap across
    /// sleep; re-enabling it keeps Push-to-Talk working so the app resumes usable
    /// rather than going quietly dead. No tap installed → surface the (unchanged)
    /// Input-Monitoring-needed state instead of failing silently (User Story 38).
    func revalidate() {
        guard let tap = eventTap else {
            logger.notice("Wake revalidation: no event tap installed (Input Monitoring not granted?).")
            onStatus?(Self.inputMonitoringNeededStatus)
            onInputMonitoringStatus?(PermissionAdvice.make(for: .inputMonitoring, status: .denied))
            return
        }
        if !CGEvent.tapIsEnabled(tap: tap) {
            CGEvent.tapEnable(tap: tap, enable: true)
            logger.notice("Re-enabled the Push-to-Talk event tap after wake.")
        }
        onStatus?(Self.readyStatus)
    }

    /// Runs on the tap's run-loop thread. Extracts primitives and hops to the main
    /// actor for the actual down/up decision + state update; it never touches
    /// `binder`/`activeHotkey` itself (those reads happen on the main actor in
    /// `process` below, or synchronously in `isBoundPushToTalkChord`, which needs an
    /// answer before this callback returns — see its doc comment).
    private func enqueue(type: CGEventType, event: CGEvent) {
        let phase: HotkeyPhase
        switch type {
        case .keyDown: phase = .down
        case .keyUp: phase = .up
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS disabled our tap (callback timeout, or a burst of user input); the
            // callback MUST re-enable it or Push-to-Talk silently dies (mirrors the
            // recovery in `revalidate()`).
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
                logger.notice("Re-enabled the Push-to-Talk event tap after macOS disabled it.")
            }
            return
        default: return  // flagsChanged etc. are not push-to-talk edges.
        }
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags.rawValue
        Task { @MainActor [weak self] in
            self?.process(keyCode: keyCode, eventFlags: flags, phase: phase)
        }
    }

    /// Whether `type`/`event` is a bound push-to-talk chord — the exact condition
    /// under which `process` below signals a PTT down/up (same `resolve` overload,
    /// same release-edge fallback, same autorepeat-keyDown behavior), reused as-is so
    /// the two decisions can never drift apart. The active tap's callback must return
    /// `nil` (consume) or the original event (pass through) before it can hand off to
    /// the main actor, so — unlike `enqueue` above — this reads `binder`/`activeHotkey`
    /// directly on the tap's own thread rather than waiting for the `Task` hop; both
    /// are plain, non-isolated properties only ever written on the main actor, and this
    /// is a same-event read-only snapshot, so it stays consistent with what `process`
    /// computes for the same event a moment later.
    private func isBoundPushToTalkChord(type: CGEventType, event: CGEvent) -> Bool {
        let phase: HotkeyPhase
        switch type {
        case .keyDown: phase = .down
        case .keyUp: phase = .up
        default: return false  // flagsChanged, tap-disabled notifications, etc.
        }
        guard let binder else { return false }
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags.rawValue
        return binder.resolve(keyCode: keyCode, eventFlags: flags, phase: phase, activeHotkey: activeHotkey) != nil
    }

    /// Main-actor reaction: ask the binder for the decision (normal chord match, or its
    /// release-edge fallback — see `HotkeyBinder.resolve(keyCode:eventFlags:phase:activeHotkey:)`)
    /// and update the held-hotkey state from the result.
    @MainActor
    private func process(keyCode: Int, eventFlags: UInt64, phase: HotkeyPhase) {
        guard let binder else { return }
        let activation = binder.resolve(
            keyCode: keyCode, eventFlags: eventFlags, phase: phase, activeHotkey: activeHotkey)
        logger.debug(
            "phase=\(String(describing: phase), privacy: .public) kc=\(keyCode, privacy: .public) m=\(activation != nil, privacy: .public)"
        )
        guard let activation else { return }

        switch activation.phase {
        case .down: activeHotkey = activation.hotkey
        case .up: activeHotkey = nil
        }
        onActivation?(activation)
    }

    deinit {
        // The tap's source lives on `tapRunLoop` (the dedicated tap thread's run loop),
        // never `CFRunLoopGetCurrent()` — deinit can run on whatever thread drops the
        // last reference, which is not necessarily that thread.
        if let source = runLoopSource, let runLoop = tapRunLoop {
            CFRunLoopRemoveSource(runLoop, source, .commonModes)
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
    }
}
