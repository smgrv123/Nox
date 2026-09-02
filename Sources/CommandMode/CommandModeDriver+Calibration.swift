import AideCore
import CommandDispatcher
import CommandRouter
import Foundation
import SkillManifest
import SpeechToText

extension CommandModeDriver {

    func log(
        transcription: Transcription? = nil,
        intent: RoutedIntent? = nil,
        outcome: DispatchOutcome? = nil,
        sttPregate: String,
        startedAt: Date,
        userOutcome: String? = nil
    ) async {
        let skillID = intent?.decision.skillID
        let manifest: Manifest? = if let skillID { await registry.manifest(for: skillID) } else { nil }
        let paramValidation: String? =
            if let intent, let skillID {
                switch await registry.validate(parameters: intent.decision.parameters, for: skillID) {
                case .success: "pass"
                case .failure: "fail"
                }
            } else {
                nil
            }
        let latencyMs = Int((Date().timeIntervalSince(startedAt) * 1000).rounded())
        let record = CalibrationRecord(
            ts: Date(),
            whisperAvgLogprob: transcription?.utteranceAvgLogprob,
            whisperMinSegmentLogprob: transcription?.segments.map(\.avgLogprob).min(),
            sttPregate: sttPregate,
            chosenSkillID: skillID,
            idSelectingTokenCount: intent?.confidence.idSelectingTokenCount,
            routingLogprobSum: intent?.confidence.logprobSum,
            routingLogprobMean: intent?.confidence.logprobMean,
            paramValidation: paramValidation,
            riskTier: manifest?.riskTier,
            scannerVerdict: outcome.flatMap { Self.scannerVerdict(skillID: skillID, outcome: $0) },
            actionTaken: outcome.map(Self.actionTaken) ?? "prompted_back",
            userOutcome: userOutcome,
            latencyMs: latencyMs
        )
        try? logger.append(record)
    }

    static func actionTaken(_ outcome: DispatchOutcome) -> String {
        switch outcome {
        case .executed: "executed"
        case .promptedBack: "prompted_back"
        case .confirmBack: "confirm_back"
        case .hardBlocked: "hard_block"
        case .failed: "prompted_back"
        }
    }

    static func scannerVerdict(skillID: String?, outcome: DispatchOutcome) -> String? {
        guard let skillID, ExecutableCommandRenderer.isExecutable(skillID) else { return nil }
        switch outcome {
        case .hardBlocked:
            return "hard_block"
        case .confirmBack(let prompt):
            if let findings = prompt.findings, !findings.isEmpty { return "confirm" }
            return "clean"
        case .executed, .promptedBack, .failed:
            return "clean"
        }
    }
}
