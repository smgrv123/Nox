import AideCore
import CommandDispatcher
import CommandRouter
import Foundation
import SpeechToText

extension CommandModeDriver {

    @MainActor
    func resolve(_ pcm: PCMBuffer, mode: VoiceSessionMode, generation: Int) async {
        let startedAt = Date()
        do {
            try await engine.ensureLoaded()
            let initialPrompt = await makeInitialPrompt()
            let transcription = try await engine.transcribe(
                Self.peakNormalize(pcm), language: .auto, initialPrompt: initialPrompt)
            guard self.generation == generation else { return }

            switch preGate.evaluate(transcription, mode: mode) {
            case .pass(let text, _):
                deliver(.transcript(text), generation: generation)
                await routeAndDispatch(
                    text: text, transcription: transcription, startedAt: startedAt,
                    generation: generation)
            case .fail:
                deliver(.result(Self.degraded(Self.reAskSummary)), generation: generation)
                await log(transcription: transcription, sttPregate: "fail", startedAt: startedAt)
            }
        } catch {
            guard self.generation == generation else { return }
            deliver(.result(Self.degraded(Self.modelNotReadySummary)), generation: generation)
            await log(sttPregate: "fail", startedAt: startedAt)
        }
    }

    @MainActor
    func routeAndDispatch(
        text: String,
        transcription: Transcription,
        startedAt: Date,
        generation: Int
    ) async {
        do {
            let endpoint = try await resolveEndpoint()
            let intent = try await router.route(
                transcript: text,
                whisperAvgLogprob: transcription.utteranceAvgLogprob,
                endpoint: endpoint)
            guard self.generation == generation else { return }

            let outcome = await dispatcher.dispatch(
                intent, whisperAvgLogprob: transcription.utteranceAvgLogprob)
            guard self.generation == generation else { return }
            await deliverOutcome(
                PendingConfirm(
                    intent: intent,
                    text: text,
                    transcription: transcription,
                    startedAt: startedAt,
                    generation: generation,
                    outcome: outcome))
        } catch {
            guard self.generation == generation else { return }
            deliver(
                .result(VoiceSessionResult(transcript: text, summary: error.localizedDescription)),
                generation: generation)
            await log(transcription: transcription, sttPregate: "pass", startedAt: startedAt)
        }
    }

    @MainActor
    func deliverOutcome(_ pending: PendingConfirm) async {
        let outcome = pending.outcome
        switch outcome {
        case .executed, .failed:
            deliver(
                .result(
                    VoiceSessionResult(transcript: pending.text, summary: Self.summary(for: outcome))),
                generation: pending.generation)
            await log(
                transcription: pending.transcription, intent: pending.intent, outcome: outcome,
                sttPregate: "pass", startedAt: pending.startedAt)
        case .confirmBack(let prompt):
            pendingConfirm = pending
            deliver(
                .confirmBack(
                    ConfirmBackInfo(
                        transcript: pending.text,
                        intent: prompt.intent,
                        skillID: prompt.skillID,
                        riskTier: prompt.riskTier)),
                generation: pending.generation)
        case .promptedBack(let suggestion):
            deliver(.promptBack(pending.text, suggestion), generation: pending.generation)
            await log(
                transcription: pending.transcription, intent: pending.intent, outcome: outcome,
                sttPregate: "pass", startedAt: pending.startedAt, userOutcome: "dismissed")
        case .hardBlocked(let reason):
            deliver(.hardBlocked(pending.text, reason), generation: pending.generation)
            await log(
                transcription: pending.transcription, intent: pending.intent, outcome: outcome,
                sttPregate: "pass", startedAt: pending.startedAt)
        }
    }

    static func summary(for outcome: DispatchOutcome) -> String {
        switch outcome {
        case .executed(let result):
            return result.summary
        case .promptedBack(let suggestion):
            return suggestion ?? ConfidenceGate.promptBackSuggestion
        case .failed(let error):
            return error
        case .confirmBack, .hardBlocked:
            preconditionFailure("confirmBack/hardBlocked are dedicated updates, not .result summaries")
        }
    }

    /// Installed-app display names for Whisper's `initialPrompt` slot, capped at 50,
    /// alphabetical, system utilities excluded. The P5b composition root merges this
    /// with dictionary terms; Command Mode no longer calls it from `resolve` directly.
    public static func appNameBiasPrompt(_ appCatalog: any InstalledApplicationCatalog) async -> String? {
        let names =
            await appCatalog.installedApplications()
            .filter { !$0.isSystemUtility }
            .map(\.displayName)
            .sorted()
            .prefix(50)
        let prompt = names.joined(separator: ", ")
        return prompt.isEmpty ? nil : prompt
    }

    static func peakNormalize(_ pcm: PCMBuffer) -> PCMBuffer {
        let targetPeak: Float = 0.9
        let maxAmp = pcm.samples.reduce(Float(0)) { max($0, abs($1)) }
        guard maxAmp > 0.001 else { return pcm }
        let gain = min(targetPeak / maxAmp, 20.0)
        guard gain > 1.05 else { return pcm }
        return PCMBuffer(samples: pcm.samples.map { $0 * gain }, sampleRate: pcm.sampleRate)
    }
}
