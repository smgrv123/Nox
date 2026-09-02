import AideCore
import Foundation

/// One JSONL line in `logs/calibration.jsonl` (docs/05-lld.md §4.2).
///
/// `user_outcome` is `null` until the user accepts, aborts, or corrects — including
/// after a successful auto-execute (no feedback yet) and while Confirm-Back /
/// prompt-back is pending.
public struct CalibrationRecord: Equatable, Sendable {
    public var ts: Date
    public var mode: String
    public var whisperAvgLogprob: Float?
    public var whisperMinSegmentLogprob: Float?
    public var sttPregate: String
    public var chosenSkillID: String?
    public var idSelectingTokenCount: Int?
    public var routingLogprobSum: Float?
    public var routingLogprobMean: Float?
    public var paramValidation: String?
    public var riskTier: RiskTier?
    public var scannerVerdict: String?
    public var actionTaken: String?
    public var userOutcome: String?
    public var latencyMs: Int

    public init(
        ts: Date,
        mode: String = "command",
        whisperAvgLogprob: Float?,
        whisperMinSegmentLogprob: Float?,
        sttPregate: String,
        chosenSkillID: String?,
        idSelectingTokenCount: Int?,
        routingLogprobSum: Float?,
        routingLogprobMean: Float?,
        paramValidation: String?,
        riskTier: RiskTier?,
        scannerVerdict: String?,
        actionTaken: String?,
        userOutcome: String? = nil,
        latencyMs: Int
    ) {
        self.ts = ts
        self.mode = mode
        self.whisperAvgLogprob = whisperAvgLogprob
        self.whisperMinSegmentLogprob = whisperMinSegmentLogprob
        self.sttPregate = sttPregate
        self.chosenSkillID = chosenSkillID
        self.idSelectingTokenCount = idSelectingTokenCount
        self.routingLogprobSum = routingLogprobSum
        self.routingLogprobMean = routingLogprobMean
        self.paramValidation = paramValidation
        self.riskTier = riskTier
        self.scannerVerdict = scannerVerdict
        self.actionTaken = actionTaken
        self.userOutcome = userOutcome
        self.latencyMs = latencyMs
    }
}

extension CalibrationRecord: Codable {
    enum CodingKeys: String, CodingKey {
        case ts
        case mode
        case whisperAvgLogprob = "whisper_avg_logprob"
        case whisperMinSegmentLogprob = "whisper_min_segment_logprob"
        case sttPregate = "stt_pregate"
        case chosenSkillID = "chosen_skill_id"
        case idSelectingTokenCount = "id_selecting_token_count"
        case routingLogprobSum = "routing_logprob_sum"
        case routingLogprobMean = "routing_logprob_mean"
        case paramValidation = "param_validation"
        case riskTier = "risk_tier"
        case scannerVerdict = "scanner_verdict"
        case actionTaken = "action_taken"
        case userOutcome = "user_outcome"
        case latencyMs = "latency_ms"
    }

    /// Always emit every LLD §4.2 key. Synthesized `Codable` would drop `nil`
    /// optionals; `user_outcome` (and scanner-skipped fields) must be JSON `null`.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(ts, forKey: .ts)
        try container.encode(mode, forKey: .mode)
        try container.encode(whisperAvgLogprob, forKey: .whisperAvgLogprob)
        try container.encode(whisperMinSegmentLogprob, forKey: .whisperMinSegmentLogprob)
        try container.encode(sttPregate, forKey: .sttPregate)
        try container.encode(chosenSkillID, forKey: .chosenSkillID)
        try container.encode(idSelectingTokenCount, forKey: .idSelectingTokenCount)
        try container.encode(routingLogprobSum, forKey: .routingLogprobSum)
        try container.encode(routingLogprobMean, forKey: .routingLogprobMean)
        try container.encode(paramValidation, forKey: .paramValidation)
        try container.encode(riskTier, forKey: .riskTier)
        try container.encode(scannerVerdict, forKey: .scannerVerdict)
        try container.encode(actionTaken, forKey: .actionTaken)
        try container.encode(userOutcome, forKey: .userOutcome)
        try container.encode(latencyMs, forKey: .latencyMs)
    }
}
