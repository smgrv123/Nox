# PRD — P4 · Command Routing & Skills

> Pillar P4 of Aide (see [`docs/07-implementation-pillars.md`](../docs/07-implementation-pillars.md)).
> Grounded in [`docs/04-hld.md`](../docs/04-hld.md) §5–6, §7.1 and [`docs/05-lld.md`](../docs/05-lld.md) §2.1–2.2, §3.1, §4.2, §4.4.
> Depends on: **P1** (Platform & Shell), **P2** (Inference Core), **P3** (Safety Guard).
> Status: draft spec · not yet planned.

## Problem Statement

Aide can now capture audio, transcribe it locally (P2a), talk to a local LLM (P2b), and detect dangerous commands (P3). But there is no bridge between "the user said something" and "something useful happens." The `STTVoiceSessionDriver` transcribes speech and shows it in the Overlay — that's where the pipeline ends today.

Command Mode needs a **routing and dispatch layer** that:

1. Takes a transcript and turns it into a structured `{intent, skill_id, parameters}` decision — the **Router Contract v2**.
2. **Constrains** that decision with a GBNF Grammar generated from the live skill set, so the model can only emit valid skill IDs and correctly-shaped parameters.
3. **Measures routing confidence** from the LLM's own logprobs at the skill-selecting tokens — not a self-reported number.
4. **Gates** execution through a composite Confidence Gate (Pre-Gate + routing logprob + schema validation + Risk Tier), producing execute / Confirm-Back / prompt-back.
5. **Dispatches** the gated decision to a Swift-backed Built-in Skill, delegating dangerous-command scanning for any executable channel.
6. **Logs** every routing decision locally for the day-one calibration harness, so thresholds can be data-fitted after ~1 week.

Without this, Aide is a transcription tool, not a voice assistant.

## Solution

A set of pure, headlessly-testable SwiftPM modules that implement the **decision core** (Layer 2) from the architecture doc:

- **`SkillManifest`** — the Swift model for the Manifest JSON schema (LLD §2.1), with Codable round-trip and validation.
- **`SkillRegistry`** — loads/watches manifest files from `registry/`, validates them, generates the Router prompt catalog and the GBNF Grammar, and validates Router-emitted parameters against the chosen skill's schema.
- **`Router`** — takes a transcript + session context, calls `LLMClient.routeComplete` with the registry-generated grammar, parses the Contract v2 JSON, and derives the Logprob-Derived Routing Confidence from `tokenLogprobs`.
- **`ConfidenceGate`** — the composite deterministic gate: assembles Pre-Gate verdict + routing logprob + schema validation + Risk Tier into an execute / Confirm-Back / prompt-back decision.
- **`Dispatcher`** — applies the gate, integrates the Dangerous-Command Scanner (P3) on executable channels, invokes Built-in Skills, and produces a `DispatchOutcome`.
- **`BuiltinSkills`** — Swift implementations of the v1 skill set.
- **`CalibrationLogger`** — the day-one local-only harness that logs routing decisions for threshold tuning.

All pure logic sits in SwiftPM modules tested headlessly (`swift test`). The App layer wires them together and replaces `STTVoiceSessionDriver`'s transcript-only flow with the full STT → Route → Gate → Dispatch pipeline.

## User Stories

### Manifest & Registry

1. As a developer building skills, I want a typed `Manifest` model that round-trips to/from the LLD §2.1 JSON schema, so manifests are validated at load time and invalid ones disable only that skill.
2. As a developer, I want the Skill Registry to generate a GBNF Grammar from the live set of enabled manifests, so the Router is structurally constrained to emit only registered skill IDs.
3. As a developer, I want the Registry to generate a Router prompt catalog (skill descriptions + parameter schemas + example utterances) from manifests, so the Router's system prompt stays in sync with the grammar.
4. As a developer, I want the generated grammar to include the mandatory `null` alternative and the reserved built-in targets `general_qa` and `screen_qa`, so the Router can express "nothing matched" and route to Q&A capabilities.

### Router

5. As a developer, I want a `Router` that calls `LLMClient.routeComplete` with the generated grammar and system prompt, parses the GBNF-constrained JSON output into a typed `RouterDecision`, and derives `RoutingConfidence` from the logprobs at the `skill_id`-selecting tokens.
6. As a user, I want the Router to always run locally (on the Sidecar), so my voice commands never leave my machine during routing.
7. As a developer, I want a `RoutingConfidence` type that carries `idSelectingTokenCount`, `logprobSum`, and `logprobMean` — the signal the Confidence Gate reads.

### Confidence Gate

8. As a user, I want `skill_id: null` to produce a prompt-back ("Did you mean…?"), never a guess-execute.
9. As a user, I want schema-validation failure to be a **HARD rejection** that produces a prompt-back, so malformed parameters never reach a skill.
10. As a user, I want `low`-risk skills to execute silently when routing confidence is above the floor, and prompt-back when it's weak.
11. As a user, I want `confirm`-risk skills to execute silently only when routing confidence is clearly high, and Confirm-Back when it's marginal.
12. As a user, I want `always_confirm` skills to **always** Confirm-Back regardless of confidence.

### Dispatcher & Scanner Integration

13. As a user, I want the Dispatcher to call the Dangerous-Command Scanner before executing any skill that produces an executable command, so the P3 safety guard is wired into the live pipeline.
14. As a user, I want Hard-Block findings to produce a `.hardBlocked` outcome with no override, and Confirm findings to produce a `.confirmBack`.
15. As a developer, I want `DispatchOutcome` to carry all possible outcomes: `.executed`, `.confirmBack`, `.hardBlocked`, `.promptedBack`, `.failed`.

### Built-in Skills

16. As a user saying "open Safari," I want the app to launch or focus Safari.
17. As a user saying "set a timer for 5 minutes," I want a local notification after 5 minutes.
18. As a user saying "what time is it in Tokyo," I want the current time in that timezone.
19. As a user saying "what's 15% of 230," I want the calculation result.
20. As a user saying "play" or "pause," I want media playback toggled.
21. As a user saying "take a screenshot," I want a screenshot saved (and the path available for Screen Q&A in P6).
22. As a user, I want `general_qa` and `screen_qa` to be recognized as reserved router targets that P6 consumes later — P4 stubs them with honest "not yet available" responses.

### Calibration Harness

23. As a developer, I want every Command Mode interaction to be logged locally (whisper logprob, routing logprob, chosen skill, risk tier, scanner verdict, action taken, user outcome) so thresholds can be calibrated after ~1 week.
24. As a developer, I want the calibration log to be JSONL, local-only, and included in "Wipe all history" scope.

### End-to-end pipeline

25. As a user, I want to hold Hotkey A, say "open Safari," release, and see Safari open — the full Command Mode pipeline working end-to-end.
26. As a user, I want the Overlay to show the transcript, then the routing result, then the outcome — the same state machine already working from P1.

## Scope

### In scope

- **Manifest model** — Swift Codable type matching LLD §2.1, with validation (required fields, id format, risk tier enum, parameter schema shape).
- **Skill Registry** — actor that loads manifests from `registry/`, validates, watches for changes, generates GBNF Grammar (LLD §4.4) and Router prompt catalog (LLD §6.1).
- **GBNF Grammar assembly** — deterministic, stable-ordered generation per LLD §2.2.2 / §4.4. Discriminated union: each skill gets one alternative with fixed `skill_id` literal + typed `parameters`.
- **Router** — calls `LLMClient.routeComplete`, parses Contract v2 JSON, derives `RoutingConfidence` from `tokenLogprobs` at the `skill_id`-selecting byte range.
- **Router prompt** — the system prompt template (LLD §6.1) with substituted skill catalog and session context.
- **Schema Validation** — validates `parameters` against the chosen manifest's parameter schema. HARD reject on failure.
- **Confidence Gate** — deterministic decision from Pre-Gate + routing logprob + Risk Tier. Provisional thresholds from LLD §4.2.
- **Dispatcher** — applies Confidence Gate, integrates Scanner (P3), invokes skills, produces `DispatchOutcome`.
- **Built-in Skills (v1 set)** — open/quit app, set timer (local notification), media control, take screenshot, current time/date + timezones, calculations + unit conversions. (Weather and calendar-read are deferred to integration phases since they need network/TCC gating respectively.)
- **Reserved targets** — `general_qa` and `screen_qa` wired as stub targets (P6 provides the real implementations).
- **Calibration Logger** — JSONL harness per LLD §4.2 / §7.
- **Pipeline wiring** — replace the transcript-only `STTVoiceSessionDriver` flow with STT → Route → Gate → Dispatch, reusing the existing `VoiceSessionDriver` seam.

### Out of scope

- **User Script-Automations** — generation, Frozen Script lifecycle, `launchctl` registration — P7.
- **Scheduling / launchd** — P7.
- **Dictation Mode** — P5.
- **General Knowledge Q&A / Screen Q&A** — the real implementations are P6. P4 stubs them.
- **Cloud Escalation / BYOK** — P6.
- **Session Context** — the rolling exchange window is P6. P4's Router prompt carries the current transcript only; follow-up/continuation detection is P6.
- **Personalization Dictionary** — P5 (bias prompt) / P6 (cleanup prompt).
- **Weather skill** (needs network disclosure) and **Calendar skill** (needs EventKit TCC) — deferred to a P4 follow-up or P6 integration. The manifests exist; the Swift implementations are stubbed.
- **Currency conversion** (needs Frankfurter API) — same deferral.
- **Confirm-Back / Hard-Block UI rendering** — P1's Overlay already handles the state transitions; P4 feeds the outcomes into it. The separate destructive-confirm modal is P1's `ConfirmationModal`.

## Interfaces

### Consumed (already built)

| Interface | Module | What P4 reads |
|---|---|---|
| `LLMClient.routeComplete(system:user:grammar:endpoint:)` | `LLMRuntime` | Grammar-constrained completion + logprobs |
| `RouterCompletion` (`.raw`, `.tokenLogprobs`) | `LLMRuntime` | Raw JSON + per-token logprobs for confidence derivation |
| `TokenLogprob` (`.token`, `.logprob`, `.byteRange`) | `LLMRuntime` | The logprob signal at `skill_id`-selecting tokens |
| `LLMEndpoint` (`.baseURL`, `.model`, `.isLocal`) | `LLMRuntime` | The local Sidecar target |
| `SidecarController.endpoint` | `LLMRuntime` | Discover the live Sidecar port |
| `CommandScanning.scan(_:context:)` | `DangerousCommandScanner` | Pre-dispatch safety check |
| `ScanVerdict`, `ScanContext`, `Finding` | `DangerousCommandScanner` | Scanner results |
| `RiskTier` | `AideCore` | Per-manifest risk classification |
| `VoiceSessionDriver` / `VoiceSessionUpdate` / `VoiceSessionResult` | `AideCore` | The seam P4's driver conformer plugs into |
| `PreGateVerdict` / `SegmentPreGate` | `SpeechToText` | Pre-routing quality gate |
| `Transcription` / `Segment` | `SpeechToText` | STT output shape |
| `OverlayStateMachine` | `Overlay` | Transition to ConfirmBack/PromptBack/ShowingResult states |
| `Persistence.StorageLayout` | `Persistence` | File paths for `registry/`, `grammar/`, `logs/` |
| `Persistence.AtomicFileWriter` | `Persistence` | Atomic manifest/grammar writes |
| `Persistence.FileAppender` | `Persistence` | Calibration log append |

### Exposed (P4 provides)

| Interface | Consumers | Shape |
|---|---|---|
| `Manifest` | P7 (Script-Automations), Settings UI | `struct Manifest: Codable, Sendable` — the full LLD §2.1 shape |
| `SkillRegistering` protocol | Router, Dispatcher | `routerGrammar()`, `routerPromptSkillCatalog()`, `manifest(for:)`, `validate(parameters:for:)` |
| `Routing` protocol | Dispatcher, AppCoordinator | `route(transcript:whisperAvgLogprob:endpoint:) async throws -> RoutedIntent` |
| `RoutedIntent` | Dispatcher | `RouterDecision` + `RoutingConfidence` |
| `RouterDecision` | Dispatcher | `intent: String`, `skillID: String?`, `parameters: JSONValue` |
| `RoutingConfidence` | Dispatcher, CalibrationLogger | `idSelectingTokenCount`, `logprobSum`, `logprobMean` |
| `Dispatching` protocol | AppCoordinator | `dispatch(_:routingConfidence:preGateLogprob:) async -> DispatchOutcome` |
| `DispatchOutcome` | Overlay, AppCoordinator | `.executed(SkillResult)`, `.confirmBack(…)`, `.hardBlocked(…)`, `.promptedBack(…)`, `.failed(…)` |
| `SkillResult` | Overlay | `let summary: String` — what happened |
| `BuiltinSkillExecutor` protocol | Dispatcher | `execute(skillID:parameters:) async throws -> SkillResult` |
| `CalibrationRecord` | CalibrationLogger | The JSONL line shape from LLD §4.2 |

### Module boundaries

```
AideCore (existing)         ← RiskTier, VoiceSessionDriver seam
  │
  ├─► SkillManifest (new)   ← Manifest type, validation, JSONValue
  │
  ├─► SkillRegistry (new)   ← SkillRegistering protocol, GBNF assembly, prompt catalog
  │     depends on: SkillManifest, Persistence, AideCore
  │
  ├─► CommandRouter (new)   ← Routing protocol, RouterDecision, RoutingConfidence,
  │     │                      ConfidenceGate, CalibrationRecord
  │     depends on: SkillManifest, LLMRuntime, SpeechToText (PreGateVerdict)
  │
  ├─► CommandDispatcher (new) ← Dispatching protocol, DispatchOutcome, SkillResult
  │     depends on: CommandRouter, SkillManifest, SkillRegistry, DangerousCommandScanner, AideCore
  │
  ├─► BuiltinSkills (new)   ← BuiltinSkillExecutor, individual skill impls
  │     depends on: SkillManifest, AideCore
  │
  └─► CalibrationLogger (new) ← CalibrationRecord, JSONL appender
        depends on: CommandRouter, Persistence
```

All depend downward only; no cycles. `CommandRouter` depends on `LLMRuntime` protocols, never on `InferenceClient` — the concrete client is injected by the App layer.

## Architectural Decisions

### AD-1: Separate modules for Router vs Dispatcher vs Registry

The Router (probabilistic → structured data), the Dispatcher (deterministic gating + execution), and the Registry (manifest storage + grammar generation) are separate modules because they have distinct responsibilities and distinct test strategies. The Router is tested with a `MockLLMClient`; the Dispatcher is tested with a mock Router + mock Scanner; the Registry is tested with fixture manifest files. Coupling them would prevent independent testing.

### AD-2: GBNF grammar is generated, never hand-maintained

The grammar is a deterministic function of the manifest set. Regenerating it on any registry change keeps the Router's legal token set in lockstep with the registered skills — no manual sync required, no drift possible.

### AD-3: `JSONValue` for parameter validation

Parameter schemas and values are represented as a recursive `JSONValue` enum (`string | int | double | bool | null | array | object`) rather than `Any` or `[String: Any]`, so validation is exhaustive, `Equatable`, and `Sendable`.

### AD-4: RoutingConfidence is measured, not modeled

The `RoutingConfidence` struct carries the raw logprob measurements and the provisional thresholds are injected (like `PreGateThresholds`), so recalibration is a one-line change. The Router never asks the model to self-report confidence.

### AD-5: Built-in skills are pure functions where possible

Skills like time/date, calculation, and unit conversion are pure functions of their parameters. Skills that interact with the system (open app, media control, screenshot) implement a protocol and are injected, so the pure routing/dispatch pipeline remains headlessly testable.

### AD-6: Reserved targets `general_qa` / `screen_qa` are manifest-registered

They appear in the manifest set and grammar like any other skill, but their `kind` is `builtin` and the Dispatcher special-cases them. In P4 they return a stub response; P6 wires the real KnowledgeQA / ScreenQA modules. This means the Router can select them with the same logprob-measurable mechanism as any skill.

## Testing Strategy

- **Unit tests** for `Manifest` Codable round-trip, validation (valid + invalid fixtures).
- **Unit tests** for GBNF Grammar assembly: given a known manifest set → assert the generated grammar text matches expected output.
- **Unit tests** for Router prompt catalog generation.
- **Unit tests** for `RoutingConfidence` derivation: given `RouterCompletion.tokenLogprobs` and a known `skill_id` byte range → assert the correct logprob extraction.
- **Unit tests** for Router Contract v2 JSON parsing: valid JSON → `RouterDecision`; malformed → error.
- **Unit tests** for parameter schema validation: valid params → pass; type mismatch / missing required → hard reject.
- **Unit tests** for `ConfidenceGate`: all combinations of Pre-Gate verdict × routing confidence × Risk Tier → expected gate outcome.
- **Unit tests** for `Dispatcher`: mock router + mock scanner → assert correct `DispatchOutcome` for each scenario (clean execute, confirm-back, hard-blocked, prompted-back, failed).
- **Unit tests** for each built-in skill (pure inputs → expected outputs).
- **Unit tests** for `CalibrationRecord` JSONL encoding.
- All tests headless (`swift test`), no native binary, no network, no TCC.
