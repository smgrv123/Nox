import AideCore
import DangerousCommandScanner
import Foundation
import LLMRuntime
import SpeechToText

/// Dictation-mode `VoiceSessionDriver`: capture → transcribe → Pre-Gate →
/// terminal-destination scan → tone cleanup → insert at the caret
/// (plans/P5a-dictation-core.md Phase 5). Overlay/coordinator stay unchanged;
/// the mux swaps this in for `STTVoiceSessionDriver` on `.dictation`.
///
/// The capture → transcribe → Pre-Gate front half is `SpeechToText.CaptureTranscribeGate`
/// (P5a extraction — shared with `STTVoiceSessionDriver`; it lives in `SpeechToText`
/// rather than `STTVoiceSession` so this pillar doesn't depend on P2a's concrete
/// module); this driver supplies the divergent tail on Pre-Gate pass (tone cleanup →
/// terminal scan → insert) and owns the generation-guarded `pendingInsert` stash for
/// Confirm-Back.
///
/// Depends on `STTEngine`, `AudioCaptureBuffer`, `SegmentPreGate`,
/// `TextInserting`, `CommandScanning`, and `LLMClient` — tests inject mocks;
/// `App/TextInserterLive.swift` is the AppKit shell. Never `InferenceClient`.
public final class DictationDriver: VoiceSessionDriver {

    public var onUpdate: ((VoiceSessionUpdate) -> Void)? {
        get { gate.onUpdate }
        set { gate.onUpdate = newValue }
    }

    // MARK: - Re-ask / degraded copy (single source; asserted by tests, never re-typed)
    //
    // Re-exported from `CaptureTranscribeGate` — see there for what each summary means
    // and when it's shown — so existing call sites (`DictationDriver.reAskSummary` etc.,
    // in this module and in `DictationDriverTests`) keep resolving unchanged.

    public static let reAskSummary = CaptureTranscribeGate.reAskSummary
    public static let modelNotReadySummary = CaptureTranscribeGate.modelNotReadySummary
    public static let microphoneUnavailableSummary = CaptureTranscribeGate.microphoneUnavailableSummary
    public static let cleanupFailedSummary = "Inserted raw — cleanup failed."
    public static let sidecarNotReadySummary = "Inserted raw — language model wasn't ready."
    public static let copiedToClipboardSummary = "Couldn't insert — copied to clipboard instead."
    public static let secureInputSummary =
        "Couldn't insert — Secure Input is on. Copied to clipboard instead."
    public static let confirmBackTimedOutSummary = "Timed out waiting for approval — copied to clipboard instead."
    public static let accessibilityDeniedSummary =
        "Text insertion needs Accessibility. Enable Aide in System Settings."

    private let gate: CaptureTranscribeGate
    private let inserter: any TextInserting
    private let scanner: any CommandScanning
    private let llm: any LLMClient
    private let resolveEndpoint: @Sendable () async throws -> LLMEndpoint
    private let tonePreset: @Sendable () -> TonePreset
    private let cleanupEnabled: @Sendable () -> Bool
    private let sidecarReadiness: @Sendable () async -> SidecarReadiness
    private let awaitSidecarReady: @Sendable (TimeInterval) async -> Bool
    private let noteSidecarActivity: @Sendable () async -> Void
    private let dictionarySubstitutions: @Sendable () async -> String
    private let appendHistory: @Sendable (DictationHistoryEntry) -> Void

    private var pendingInsert: PendingInsert?

    fileprivate struct PendingInsert {
        /// The cleaned text — what gets inserted (and what Confirm-Back showed).
        let text: String
        /// The raw, pre-cleanup remainder — recorded as `DictationHistoryEntry.transcript`.
        let rawText: String
        let generation: Int
        let focus: InsertionFocus
        /// Cleanup already ran in `scanThenInsert`; carried through so `performInsert`
        /// doesn't re-run it.
        let cleanup: DictationCleanupOutcome
        /// Capture/decode timings from the gate, plus this turn's cleanup duration —
        /// carried through so `performInsert` can time the insert and append one
        /// fully-populated `DictationHistoryEntry` (P5a latency instrumentation).
        let timings: CaptureTranscribeGate.Timings
        /// The whole cleanup step's duration; `nil` when cleanup didn't run (mirrors
        /// `cleanup.didRun`).
        let cleanupMs: Int?
    }

    public init(
        engine: any STTEngine,
        capture: any AudioCaptureBuffer,
        preGate: SegmentPreGate,
        inserter: any TextInserting,
        scanner: any CommandScanning,
        llm: any LLMClient,
        resolveEndpoint: @escaping @Sendable () async throws -> LLMEndpoint,
        tonePreset: @escaping @Sendable () -> TonePreset = { .asIs },
        cleanupEnabled: @escaping @Sendable () -> Bool = { true },
        sidecarReadiness: @escaping @Sendable () async -> SidecarReadiness = { .ready },
        awaitSidecarReady: @escaping @Sendable (TimeInterval) async -> Bool = { _ in true },
        noteSidecarActivity: @escaping @Sendable () async -> Void = {},
        makeInitialPrompt: @escaping @Sendable () async -> String? = { nil },
        dictionarySubstitutions: @escaping @Sendable () async -> String = { "" },
        appendHistory: @escaping @Sendable (DictationHistoryEntry) -> Void = { _ in }
    ) {
        self.inserter = inserter
        self.scanner = scanner
        self.llm = llm
        self.resolveEndpoint = resolveEndpoint
        self.tonePreset = tonePreset
        self.cleanupEnabled = cleanupEnabled
        self.sidecarReadiness = sidecarReadiness
        self.awaitSidecarReady = awaitSidecarReady
        self.noteSidecarActivity = noteSidecarActivity
        self.dictionarySubstitutions = dictionarySubstitutions
        self.appendHistory = appendHistory
        self.gate = CaptureTranscribeGate(
            engine: engine, capture: capture, preGate: preGate, makeInitialPrompt: makeInitialPrompt)
        self.gate.onPass = { [weak self] text, generation, timings in
            await self?.scanThenInsert(text, generation: generation, timings: timings)
        }
    }

    public func begin(mode: VoiceSessionMode) {
        pendingInsert = nil
        gate.begin(mode: mode)
        noteActivityIfCleanupEnabled()
        firePrefillIfCleanupEnabled()
    }

    /// Notes sidecar activity when cleanup is on — once at hotkey key-down (warming the
    /// model loader with the whole utterance still ahead of it), and again at flow
    /// completion (so the idle countdown restarts from the end of the flow, not the
    /// middle). Fire-and-forget by design via an unstructured `Task`: this must never
    /// block capture or insertion.
    private func noteActivityIfCleanupEnabled() {
        guard cleanupEnabled() else { return }
        Task {
            await noteSidecarActivity()
        }
    }

    /// Fires the cleanup-prompt prefill (`DictationDriver+Prefill.swift`) at hotkey
    /// key-down, while the user is still speaking and before Whisper has produced any
    /// transcript — capture is the only idle window this flow has. Fire-and-forget via
    /// an unstructured `Task`, same as `noteActivityIfCleanupEnabled` above: prefill is
    /// pure latency optimization and must never block or delay capture.
    private func firePrefillIfCleanupEnabled() {
        guard cleanupEnabled() else { return }
        let context = PrefillContext(
            llm: llm,
            resolveEndpoint: resolveEndpoint,
            tonePreset: tonePreset,
            sidecarReadiness: sidecarReadiness,
            dictionarySubstitutions: dictionarySubstitutions)
        Task {
            await Self.firePrefill(context)
        }
    }

    public func end() {
        gate.end()
    }

    public func cancel() {
        pendingInsert = nil
        gate.cancel()
    }

    public func approve() {
        guard let pending = pendingInsert else { return }
        pendingInsert = nil
        let generation = pending.generation
        Task { @MainActor [weak self] in
            guard let self, self.gate.generation == generation else { return }
            await self.performInsert(pending)
        }
    }

    public func reject() {
        guard let pending = pendingInsert else { return }
        pendingInsert = nil
        let generation = pending.generation
        let text = pending.text
        Task { @MainActor [weak self] in
            guard let self, self.gate.generation == generation else { return }
            self.gate.deliver(
                .result(VoiceSessionResult(transcript: text, summary: "Cancelled.")),
                generation: generation)
        }
    }

    /// Confirm-Back's safety-net timeout fired before the user answered. The safety
    /// guarantee is unchanged — never insert an unapproved command — but silently
    /// discarding the dictated text on top of that would compound one problem
    /// (missed the prompt in time) with another (the words are gone for good). So
    /// this preserves the text on the clipboard, the same escape hatch a failed
    /// insert already uses (`copiedToClipboardSummary`), just worded for this case.
    public func confirmBackTimedOut() {
        guard let pending = pendingInsert else { return }
        pendingInsert = nil
        let generation = pending.generation
        let text = pending.text
        Task { @MainActor [weak self] in
            guard let self, self.gate.generation == generation else { return }
            await self.inserter.copyToClipboard(text)
            self.gate.deliver(
                .result(VoiceSessionResult(transcript: text, summary: Self.confirmBackTimedOutSummary)),
                generation: generation)
        }
    }
}

extension DictationDriver {

    @MainActor
    fileprivate func scanThenInsert(
        _ text: String, generation: Int, timings: CaptureTranscribeGate.Timings
    ) async {
        let parsed = TonePrefixParser().parse(text)
        let remainder = parsed.remainder
        let tone = parsed.preset ?? tonePreset()
        let focus = await inserter.resolveFocus()
        let isTerminal = focus.bundleID.map { TerminalBundleIDs.allowlist.contains($0) } ?? false

        let (cleanup, cleanupMs) = await resolveCleanup(remainder: remainder, tone: tone, isTerminal: isTerminal)
        guard gate.generation == generation else { return }

        let pending = PendingInsert(
            text: cleanup.text,
            rawText: remainder,
            generation: generation,
            focus: focus,
            cleanup: cleanup,
            timings: timings,
            cleanupMs: cleanupMs)

        if isTerminal, let bundleID = focus.bundleID {
            let verdict = scanner.scan(
                cleanup.text,
                context: ScanContext(
                    channel: .dictatedOneOff,
                    destinationBundleID: bundleID,
                    manifestID: nil))
            switch verdict {
            case .clean:
                break
            case .confirm:
                pendingInsert = pending
                gate.deliver(
                    .confirmBack(
                        ConfirmBackInfo(
                            transcript: cleanup.text,
                            intent: cleanup.text,
                            skillID: "dictation_insert",
                            riskTier: .alwaysConfirm)),
                    generation: generation)
                return
            case .hardBlock(let findings):
                gate.deliver(
                    .hardBlocked(cleanup.text, findings.first?.explanation ?? "Blocked"),
                    generation: generation)
                return
            }
        }

        await performInsert(pending)
    }

    /// Runs cleanup, unless the destination is a terminal — in which case cleanup is
    /// skipped entirely: dictated shell commands must stay verbatim (the tone
    /// prompt's mandated capitalisation/terminal punctuation would otherwise corrupt
    /// `git status` into `Git status.`), and it drops ~5.5s of LLM latency where it's
    /// least wanted. The invariant this preserves — the string that's scanned is
    /// exactly the string that's inserted, and Confirm-Back previews that same
    /// string — holds trivially since both are `remainder` either way.
    @MainActor
    fileprivate func resolveCleanup(
        remainder: String, tone: TonePreset, isTerminal: Bool
    ) async -> (DictationCleanupOutcome, Int?) {
        guard !isTerminal else { return (.skipped(remainder), nil) }
        let cleanupStart = ContinuousClock.now
        let cleanup = await runDictationCleanup(raw: remainder, tone: tone)
        let cleanupMs = cleanup.didRun ? Self.elapsedMs(since: cleanupStart) : nil
        return (cleanup, cleanupMs)
    }

    @MainActor
    fileprivate func performInsert(_ pending: PendingInsert) async {
        let insertStart = ContinuousClock.now
        let insertion = await inserter.insert(pending.text)
        let insertMs = Self.elapsedMs(since: insertStart)
        guard gate.generation == pending.generation else { return }

        // Compute the summary from the original result — including its `reason`,
        // e.g. to distinguish Secure Input — before it's collapsed to
        // `.copiedToClipboard` below for history/telemetry purposes.
        let summary = Self.resultSummary(
            insertion: insertion,
            cleanupOutcome: pending.cleanup,
            accessibilityTrusted: pending.focus.accessibilityTrusted)

        var recordedInsertion = insertion
        if case .failed = insertion {
            await inserter.copyToClipboard(pending.text)
            recordedInsertion = .copiedToClipboard
        }

        let totalMs = Self.elapsedMs(since: pending.timings.captureEndedAt)
        appendHistory(
            DictationHistoryEntry(
                transcript: pending.rawText,
                cleaned: pending.cleanup.cleanedText,
                cleanupRan: pending.cleanup.didRun,
                insertion: Self.historyInsertion(recordedInsertion),
                destinationBundleID: pending.focus.bundleID,
                audioMs: pending.timings.audioMs,
                sttMs: pending.timings.sttMs,
                modelLoadMs: pending.timings.modelLoadMs,
                cleanupMs: pending.cleanupMs,
                insertMs: insertMs,
                totalMs: totalMs))

        gate.deliver(.transcript(pending.text), generation: pending.generation)
        gate.deliver(
            .result(VoiceSessionResult(transcript: pending.text, summary: summary)),
            generation: pending.generation)

        noteActivityIfCleanupEnabled()
    }

}

// `internal` (not `private`) because `DictationDriver+Reporting.swift`'s
// `resultSummary` — a same-type-extension `static func` in another file — takes this
// as a parameter; `private` is file-scoped in Swift and wouldn't be visible there.
enum DictationCleanupOutcome {
    case cleaned(String)
    case skipped(String)
    case sidecarNotReady(String)
    case chatFailed(String)

    var text: String {
        switch self {
        case .cleaned(let text), .skipped(let text), .sidecarNotReady(let text),
            .chatFailed(let text):
            return text
        }
    }

    /// The copy to show in the Overlay result — the cleaned text itself for
    /// `.cleaned`/`.skipped`, or a human-readable status string otherwise.
    var overlayCopy: String {
        switch self {
        case .cleaned(let text), .skipped(let text):
            return text
        case .sidecarNotReady:
            return DictationDriver.sidecarNotReadySummary
        case .chatFailed:
            return DictationDriver.cleanupFailedSummary
        }
    }

    var cleanedText: String? {
        if case .cleaned(let text) = self { return text }
        return nil
    }

    /// PRD: history records *whether cleanup ran*, not whether it succeeded.
    /// True only when the local LLM was actually called (`.cleaned` / `.chatFailed`).
    var didRun: Bool {
        switch self {
        case .cleaned, .chatFailed:
            return true
        case .skipped, .sidecarNotReady:
            return false
        }
    }
}

// Measured against the live sidecar: Qwen3's default hybrid reasoning mode turns a
// one-line, 9-word cleanup into 597 completion tokens (2802 chars of reasoning_content)
// for a 40-char answer — 12-40s at ~17.4 tok/s. `disableThinking: true` sends
// `chat_template_kwargs: {enable_thinking: false}` for this call only (never
// command-mode routing), cutting the same request to 1.5-2.2s. `maxTokens: 1024` stays
// as-is — long dictated paragraphs need the headroom, and a low cap risks truncating
// inside a reasoning block and returning empty content.
private let dictationCleanupSampling = SamplingParams(
    temperature: 0.2, topP: 1.0, maxTokens: 1024, topLogprobs: 0, disableThinking: true)

extension DictationDriver {
    fileprivate func runDictationCleanup(raw: String, tone: TonePreset) async -> DictationCleanupOutcome {
        guard cleanupEnabled() else {
            return .skipped(raw)
        }
        switch SidecarReadinessPolicy.decide(await sidecarReadiness()) {
        case .proceed:
            break
        case .waitUpTo(let deadline):
            guard await awaitSidecarReady(deadline) else { return .sidecarNotReady(raw) }
        case .insertRaw:
            return .sidecarNotReady(raw)
        }

        let endpoint: LLMEndpoint
        do {
            endpoint = try await resolveEndpoint()
        } catch {
            return .skipped(raw)
        }
        guard endpoint.isLocal else {
            return .skipped(raw)
        }

        do {
            let substitutions = await dictionarySubstitutions()
            let prompt = CleanupPromptBuilder.build(
                tone: tone,
                substitutions: substitutions,
                rawTranscript: raw)
            let stream = try await llm.chat(
                system: CleanupPromptBuilder.system,
                messages: [ChatMessage(role: .user, content: prompt)],
                params: dictationCleanupSampling,
                endpoint: endpoint,
                stream: false)
            var combined = ""
            for try await chunk in stream {
                combined += chunk.delta
            }
            return .cleaned(CleanupResponseSanitizer.sanitize(combined))
        } catch {
            return .chatFailed(raw)
        }
    }
}
