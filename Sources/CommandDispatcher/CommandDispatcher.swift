import CommandRouter
import DangerousCommandScanner
import SkillManifest
import SkillRegistry

/// Scans executable skills, applies the Confidence Gate, then invokes the
/// ``BuiltinSkillExecutor`` (docs/05-lld.md §3.1; plan Phase 5).
public struct CommandDispatcher: Dispatching, Sendable {
    private let registry: any SkillRegistering
    private let scanner: any CommandScanning
    private let executor: any BuiltinSkillExecutor
    private let gate: ConfidenceGate

    public init(
        registry: any SkillRegistering,
        scanner: any CommandScanning,
        executor: any BuiltinSkillExecutor,
        thresholds: RoutingThresholds
    ) {
        self.registry = registry
        self.scanner = scanner
        self.executor = executor
        self.gate = ConfidenceGate(thresholds: thresholds)
    }

    public func dispatch(
        _ intent: RoutedIntent,
        whisperAvgLogprob _: Float
    ) async -> DispatchOutcome {
        guard let skillID = intent.decision.skillID else {
            return Self.promptedBack
        }
        return await dispatchKnownSkill(skillID, intent: intent)
    }

    private func dispatchKnownSkill(
        _ skillID: String,
        intent: RoutedIntent
    ) async -> DispatchOutcome {
        guard let manifest = await registry.manifest(for: skillID) else {
            return .failed(error: "unknown skill: \(skillID)")
        }
        let validation = await registry.validate(
            parameters: intent.decision.parameters,
            for: skillID
        )
        if case .failure = validation {
            return Self.promptedBack
        }
        return await dispatchValidated(skillID, intent: intent, manifest: manifest)
    }

    private func dispatchValidated(
        _ skillID: String,
        intent: RoutedIntent,
        manifest: Manifest
    ) async -> DispatchOutcome {
        let scan = scanIfExecutable(skillID, intent: intent, manifest: manifest)
        if let scan, case .hardBlocked = scan {
            return scan
        }
        let decision = gate.decide(intent, riskTier: manifest.riskTier, schemaValid: true)
        if case .promptBack(let suggestion) = decision {
            return .promptedBack(suggestion: suggestion)
        }
        if let scan, case .confirmBack = scan {
            return scan
        }
        if case .confirmBack = decision {
            return .confirmBack(prompt: confirmPrompt(intent, skillID: skillID, manifest: manifest))
        }
        return await execute(skillID, parameters: intent.decision.parameters)
    }

    private func scanIfExecutable(
        _ skillID: String,
        intent: RoutedIntent,
        manifest: Manifest
    ) -> DispatchOutcome? {
        guard
            let command = ExecutableCommandRenderer.render(
                skillID: skillID,
                parameters: intent.decision.parameters
            )
        else {
            return nil
        }
        let verdict = scanner.scan(command, context: ScanContext(channel: .preExecution))
        return outcome(from: verdict, intent: intent, skillID: skillID, manifest: manifest)
    }

    private func outcome(
        from verdict: ScanVerdict,
        intent: RoutedIntent,
        skillID: String,
        manifest: Manifest
    ) -> DispatchOutcome? {
        switch verdict {
        case .clean:
            return nil
        case .hardBlock(let findings):
            return .hardBlocked(reason: Self.hardBlockReason(findings))
        case .confirm(let findings):
            return .confirmBack(
                prompt: confirmPrompt(
                    intent, skillID: skillID, manifest: manifest, findings: findings))
        }
    }

    private func execute(
        _ skillID: String,
        parameters: JSONValue
    ) async -> DispatchOutcome {
        if let stub = Self.qaStub(for: skillID) {
            return .executed(stub)
        }
        do {
            let result = try await executor.execute(skillID: skillID, parameters: parameters)
            return .executed(result)
        } catch {
            return .failed(error: error.localizedDescription)
        }
    }

    private func confirmPrompt(
        _ intent: RoutedIntent,
        skillID: String,
        manifest: Manifest,
        findings: [Finding]? = nil
    ) -> ConfirmBackPrompt {
        ConfirmBackPrompt(
            intent: intent.decision.intent,
            skillID: skillID,
            findings: findings,
            riskTier: manifest.riskTier
        )
    }

    private static func qaStub(for skillID: String) -> SkillResult? {
        switch skillID {
        case "general_qa":
            return SkillResult(summary: "General Q&A is not yet available")
        case "screen_qa":
            return SkillResult(summary: "Screen Q&A is not yet available")
        default:
            return nil
        }
    }

    private static var promptedBack: DispatchOutcome {
        .promptedBack(suggestion: ConfidenceGate.promptBackSuggestion)
    }

    private static func hardBlockReason(_ findings: [Finding]) -> String {
        findings.first?.explanation ?? "blocked by the command scanner"
    }
}
