# Plan: P4 · Command Routing & Skills

> Source PRD: `specs/P4-command-routing-and-skills.md`
> Depends on: P1 (Platform & Shell), P2 (Inference Core), P3 (Safety Guard) — all complete.
> Grounded in: HLD §5–6, §7.1; LLD §2.1–2.2, §3.1, §4.2, §4.4.

## Architectural decisions

Durable decisions that apply across all phases:

- **Module layout**: five new SwiftPM modules (`SkillManifest`, `SkillRegistry`, `CommandRouter`, `CommandDispatcher`, `BuiltinSkills`) plus `CalibrationLogger`. All depend downward only; no cycles. Registered in `Package.swift` and (where app-linked) `project.yml`.
- **Manifest schema**: Swift Codable struct matching LLD §2.1 JSON schema exactly. `id` is `^[a-z][a-z0-9_]{2,63}$`. `risk_tier` maps to `AideCore.RiskTier`. `parameters` field is a JSON Schema subset represented as `JSONValue`.
- **JSONValue**: recursive enum (`string | int | double | bool | null | array | object`) — `Codable`, `Equatable`, `Sendable`. Used for both parameter schemas and parameter values.
- **GBNF grammar shape**: discriminated union (LLD §2.2.2). Each enabled skill contributes one alternative whose `skill_id` is a fixed literal. `intent` is emitted first (free-text). `null` is always present. `general_qa` and `screen_qa` are reserved built-in router targets.
- **RoutingConfidence**: measured from `TokenLogprob` at the `skill_id`-selecting byte range, not self-reported. Provisional thresholds injected (like `PreGateThresholds`).
- **Confidence Gate order** (LLD §3.1, MUST): (1) Pre-Gate already applied upstream; (2) `skill_id == null` → prompt-back; (3) schema validation → fail → prompt-back; (4) Scanner on executable channels → Hard-Block or Confirm; (5) Risk Tier × routing logprob → execute / Confirm-Back / prompt-back.
- **Built-in skill execution**: pure skills (calc, time, unit conversion) are value-in → value-out functions. Effectful skills (open app, media, screenshot, timer) implement a `SystemSkillExecutor` protocol injected by the App layer, so the pipeline tests headlessly with a mock.
- **Calibration log**: one JSONL line per Command Mode interaction, appended via `Persistence.FileAppender` to `logs/calibration.jsonl`. Schema per LLD §4.2.
- **Testing**: all headless (`swift test`). Router tested with `MockLLMClient`. Dispatcher tested with mock router + mock scanner + mock skills. No native binary, no network, no TCC.

---

## Phase 1: Manifest model + JSONValue + validation

**User stories**: 1

### What to build

The foundation type the entire pillar builds on: a Swift `Manifest` struct that Codable-round-trips to/from the LLD §2.1 JSON schema, plus the `JSONValue` recursive enum for parameter schemas and values, plus validation that rejects malformed manifests gracefully (disable the skill, never crash).

Create a `SkillManifest` SwiftPM module (no dependencies beyond Foundation) containing:

- `JSONValue` — recursive `Codable`, `Equatable`, `Sendable` enum.
- `Manifest` — all fields from LLD §2.1 (`schema_version`, `id`, `kind`, `display_name`, `description`, `utterance_examples`, `parameters`, `permissions`, `schedule`, `risk_tier`, `enabled`, `script_ref`, `script_sha256`, `timeout_seconds`, `failure_state`, `created_at`, `updated_at`, `generated_by`). Import `AideCore.RiskTier` for the `risk_tier` field.
- `ManifestValidation` — validates a decoded Manifest: id regex, required fields present per `kind`, `script_ref`/`script_sha256` required iff `user_automation`, `risk_tier` is a valid enum, `parameters.type == "object"`.
- Fixture manifest JSON files for the v1 built-in skills: `open_application`, `quit_application`, `set_timer`, `media_control`, `take_screenshot`, `current_time`, `calculate`, `general_qa`, `screen_qa`.

### Acceptance criteria

- [x] `JSONValue` encodes/decodes all JSON types including nested objects and arrays
- [x] `Manifest` round-trips (encode → decode → re-encode) for a valid built-in manifest
- [x] `Manifest` round-trips for a valid `user_automation` manifest (with `script_ref`, `script_sha256`, `schedule`)
- [x] `ManifestValidation` rejects an id that doesn't match `^[a-z][a-z0-9_]{2,63}$`
- [x] `ManifestValidation` rejects a `user_automation` manifest missing `script_ref`
- [x] `ManifestValidation` rejects a `builtin` manifest that has `script_ref != null`
- [x] `ManifestValidation` accepts all v1 fixture manifests
- [x] `failure_state` fields have correct defaults when absent from JSON
- [x] Module registered in `Package.swift`; `just check` passes

---

## Phase 2: Skill Registry + GBNF Grammar assembly + prompt catalog

**User stories**: 2, 3, 4

### What to build

The `SkillRegistry` module: an actor that loads manifest files, validates them, generates the GBNF Grammar and Router prompt catalog, and exposes manifest lookup + parameter validation.

- `SkillRegistering` protocol (the DI seam) with: `skills`, `manifest(for:)`, `routerGrammar()`, `routerPromptSkillCatalog()`, `validate(parameters:for:)`.
- `InMemorySkillRegistry` — the test-first implementation: constructed from a `[Manifest]`, no filesystem. Invalid manifests are filtered out (disabled, never crash).
- `GBNFGrammarAssembler` — deterministic, stable-ordered grammar generation per LLD §2.2.2 / §4.4. Each enabled manifest → one skill alternative with a fixed `skill_id` literal and typed `parameters` block. Mandatory `null` alternative. `general_qa` and `screen_qa` alternatives. Shared JSON terminals (`string`, `char`, `hex`, `integer`, `ws`).
- `RouterPromptCatalog` — generates the skill catalog text injected into the Router system prompt: for each enabled manifest, its `id`, `description`, parameter schema summary, and `utterance_examples`.
- Parameter schema validation: given a `JSONValue` (the Router's emitted `parameters`) and a manifest's parameter schema (`Manifest.parameters`), validate type correctness, required fields present, no additional properties. Return `Result<Void, ValidationError>`.

### Acceptance criteria

- [ ] `InMemorySkillRegistry` filters out manifests that fail validation; retains valid ones
- [ ] `routerGrammar()` for a known 3-skill set produces the expected GBNF text (discriminated union with `intent` first, each skill alternative, `null` alternative)
- [ ] The grammar includes `general_qa` and `screen_qa` as reserved alternatives
- [ ] `routerPromptSkillCatalog()` includes each enabled skill's description and parameter schema
- [ ] `validate(parameters:for:)` passes for correctly-typed parameters
- [ ] `validate(parameters:for:)` rejects missing required fields
- [ ] `validate(parameters:for:)` rejects wrong-type parameter values
- [ ] `validate(parameters:for:)` rejects additional properties when `additionalProperties: false`
- [ ] Grammar output is deterministic (same input → same output) and stably ordered by `id`
- [ ] Module registered in `Package.swift`; `just check` passes

---

## Phase 3: Router Contract v2 parsing + RoutingConfidence derivation

**User stories**: 5, 6, 7

### What to build

The `CommandRouter` module: parses the GBNF-constrained JSON from `RouterCompletion.raw` into a typed `RouterDecision`, and derives `RoutingConfidence` from `RouterCompletion.tokenLogprobs` by locating the `skill_id`-selecting tokens.

- `RouterDecision` — `intent: String`, `skillID: String?`, `parameters: JSONValue`.
- `RouterContractParser` — parses a raw JSON string into a `RouterDecision`. Handles `skill_id: null` (→ `skillID = nil`).
- `RoutingConfidence` — `idSelectingTokenCount: Int`, `logprobSum: Float`, `logprobMean: Float`.
- `RoutingConfidenceDeriver` — given `RouterCompletion` (raw + tokenLogprobs), locates the byte range of the `skill_id` value in `raw`, collects the `TokenLogprob`s whose `byteRange` overlaps it, computes sum and mean.
- `RoutingThresholds` — provisional thresholds (injected, like `PreGateThresholds`): `routeHigh` (PROVISIONAL -0.15), `routeLow` (PROVISIONAL -0.7).
- `Routing` protocol (the DI seam) — `route(transcript:whisperAvgLogprob:endpoint:) async throws -> RoutedIntent`. P4's conformer calls `LLMClient.routeComplete`, parses, derives confidence.
- `RoutedIntent` — bundles `RouterDecision` + `RoutingConfidence`.
- Router system prompt template (LLD §6.1) with `{{SKILL_CATALOG}}` and `{{TRANSCRIPT}}` substitutions. (Session context substitution is a stub/empty for now — P6.)

### Acceptance criteria

- [ ] `RouterContractParser` parses valid Contract v2 JSON into `RouterDecision` with correct `intent`, `skillID`, `parameters`
- [ ] `RouterContractParser` parses `"skill_id": null` into `skillID = nil`
- [ ] `RouterContractParser` returns an error for malformed/non-JSON input
- [ ] `RoutingConfidenceDeriver` correctly locates the `skill_id` byte range in the raw JSON
- [ ] `RoutingConfidenceDeriver` collects overlapping `TokenLogprob`s and computes sum + mean
- [ ] `RoutingConfidenceDeriver` handles multi-token skill IDs (e.g. `"open_application"` tokenized as multiple tokens)
- [ ] `RoutingConfidenceDeriver` handles `skill_id: null` (the `null` literal tokens)
- [ ] `RoutingThresholds.provisional` matches the LLD §4.2 values
- [ ] `Routing` protocol conformer (with `MockLLMClient`) returns the expected `RoutedIntent` for a canned completion
- [ ] Module registered in `Package.swift`; `just check` passes

---

## Phase 4: Confidence Gate + Schema Validation

**User stories**: 8, 9, 10, 11, 12

### What to build

The deterministic `ConfidenceGate` inside the `CommandRouter` module: combines Pre-Gate verdict + RoutingConfidence + schema validation + Risk Tier into a gate decision.

- `GateDecision` — `.execute`, `.confirmBack(prompt: String)`, `.promptBack(suggestion: String?)`, `.hardBlocked(reason: String)`.
- `ConfidenceGate` — a pure struct that takes `RoutedIntent`, `PreGateVerdict` (from P2a), `RiskTier`, and a schema validation result, and produces a `GateDecision` per the LLD §3.1 dispatch decision order:
  1. `skillID == nil` → `.promptBack`
  2. Schema validation failed → `.promptBack` (treated as low confidence)
  3. `L_mean < routeLow` → `.promptBack` (even for `low`-tier)
  4. `always_confirm` → `.confirmBack` (regardless of logprob)
  5. `confirm` + `L_mean < routeHigh` → `.confirmBack`
  6. `confirm` + `L_mean >= routeHigh` → `.execute`
  7. `low` → `.execute`

### Acceptance criteria

- [ ] `null` skill → `.promptBack` regardless of confidence
- [ ] Schema validation fail → `.promptBack`
- [ ] `low` tier + above floor → `.execute`
- [ ] `low` tier + below `routeLow` → `.promptBack`
- [ ] `confirm` tier + logprob clearly high (≥ `routeHigh`) → `.execute`
- [ ] `confirm` tier + marginal logprob → `.confirmBack`
- [ ] `confirm` tier + below `routeLow` → `.promptBack`
- [ ] `always_confirm` tier + high logprob → `.confirmBack` (always, per spec)
- [ ] `always_confirm` tier + low logprob → `.confirmBack` (still not prompt-back — the action was resolved)
- [ ] Injected thresholds are used (not hardcoded); changing them changes the gate outcome
- [ ] `just check` passes

---

## Phase 5: Dispatcher + Scanner integration

**User stories**: 13, 14, 15

### What to build

The `CommandDispatcher` module: takes a `RoutedIntent`, applies the `ConfidenceGate`, integrates the `CommandScanning` (P3) scanner on executable channels, invokes the selected skill, and produces a `DispatchOutcome`.

- `DispatchOutcome` — `.executed(SkillResult)`, `.confirmBack(prompt: ConfirmBackPrompt)`, `.hardBlocked(reason: String)`, `.promptedBack(suggestion: String?)`, `.failed(error: String)`.
- `SkillResult` — `let summary: String` (what happened, shown in the Overlay).
- `ConfirmBackPrompt` — `intent: String`, `skillID: String`, `findings: [Finding]?` (scanner findings if present), `riskTier: RiskTier`.
- `Dispatching` protocol (DI seam) — `dispatch(_:routingConfidence:whisperAvgLogprob:) async -> DispatchOutcome`.
- `CommandDispatcherImpl` — constructed with a `SkillRegistering`, a `CommandScanning`, a `BuiltinSkillExecutor`, and `RoutingThresholds`. Applies the gate, calls the scanner on executable channels (context: `.preExecution`), invokes the skill executor.
- Dispatcher follows the LLD §3.1 dispatch decision order exactly: gate first, then scanner, then execute.

### Acceptance criteria

- [ ] Clean gate + clean scan → `.executed` with the skill result
- [ ] Clean gate + scanner `confirm` → `.confirmBack` with findings
- [ ] Clean gate + scanner `hardBlock` → `.hardBlocked` with reason
- [ ] Gate `.promptBack` → `.promptedBack` (scanner never called)
- [ ] Gate `.confirmBack` → `.confirmBack` (scanner still called; findings merged if any)
- [ ] Skill execution throws → `.failed`
- [ ] `general_qa` / `screen_qa` are dispatched but produce stub "not yet available" results
- [ ] Scanner is called with `ScanContext(channel: .preExecution)` for built-in skills that produce commands
- [ ] Scanner is NOT called for pure compute skills (calc, time) that produce no executable
- [ ] Module registered in `Package.swift`; `just check` passes

---

## Phase 6: Built-in Skills

**User stories**: 16, 17, 18, 19, 20, 21, 22

### What to build

The `BuiltinSkills` module: Swift implementations of the v1 skill set. Pure skills are tested directly; effectful skills implement a `SystemSkillExecutor` protocol so the App layer injects the real implementation and tests use a mock.

- `BuiltinSkillExecutor` protocol — `execute(skillID: String, parameters: JSONValue) async throws -> SkillResult`.
- `BuiltinSkillRouter` — routes a `skillID` to the correct implementation.
- Pure skills (stateless functions, no I/O):
  - `CurrentTimeSkill` — returns the current time, optionally in a named timezone. Parameters: `timezone: String?`.
  - `CalculateSkill` — evaluates a mathematical expression. Parameters: `expression: String`.
  - Stub: `GeneralQASkill` — returns "General Q&A is not yet available" (P6 wires the real one).
  - Stub: `ScreenQASkill` — returns "Screen Q&A is not yet available" (P6 wires the real one).
- Effectful skills (protocol-gated):
  - `OpenApplicationSkill` — launches or focuses a macOS app. Parameters: `app_name: String`. Needs `NSWorkspace`.
  - `QuitApplicationSkill` — quits a running app. Parameters: `app_name: String`. Needs `NSRunningApplication`.
  - `SetTimerSkill` — schedules a local notification. Parameters: `duration_seconds: Int`, `label: String?`. Needs `UNUserNotificationCenter`.
  - `MediaControlSkill` — play/pause/next/previous. Parameters: `action: String` (enum: play, pause, next, previous). Needs `MediaPlayer` / system media keys.
  - `TakeScreenshotSkill` — captures the screen to a file. Parameters: `region: String?` (full, window, selection). Needs `screencapture`.
- Manifest fixture JSON for each skill (already drafted in Phase 1) is finalized with correct parameter schemas and risk tiers.

### Acceptance criteria

- [ ] `CurrentTimeSkill` returns the correct time for "UTC", "Asia/Tokyo", "America/New_York"
- [ ] `CurrentTimeSkill` returns local time when no timezone is specified
- [ ] `CalculateSkill` evaluates `"15% of 230"` (or `"0.15 * 230"`) correctly
- [ ] `CalculateSkill` handles basic arithmetic: `+`, `-`, `*`, `/`, `%`, parentheses
- [ ] `CalculateSkill` returns a human-readable error for malformed expressions (never crashes)
- [ ] `GeneralQASkill` stub returns a "not yet available" message
- [ ] `ScreenQASkill` stub returns a "not yet available" message
- [ ] `OpenApplicationSkill` protocol method is called with the correct app name
- [ ] `QuitApplicationSkill` protocol method is called with the correct app name
- [ ] `SetTimerSkill` protocol method is called with the correct duration and label
- [ ] `MediaControlSkill` protocol method is called with the correct action
- [ ] `TakeScreenshotSkill` protocol method is called with the correct region
- [ ] Each skill has a corresponding valid manifest fixture
- [ ] Module registered in `Package.swift`; `just check` passes

---

## Phase 7: Pipeline wiring + Calibration Logger

**User stories**: 23, 24, 25, 26

### What to build

Wire the full Command Mode pipeline end-to-end and add the day-one calibration harness.

- `CommandModeDriver` — a new `VoiceSessionDriver` conformer that orchestrates: capture → STT → Pre-Gate → Route → Gate → Dispatch → deliver result through `onUpdate`. This replaces the transcript-only path in `STTVoiceSessionDriver` for Command Mode (Dictation Mode remains STT-only, which P5 will extend).
- `CalibrationLogger` — appends one JSONL line per Command Mode interaction to `logs/calibration.jsonl` via `Persistence.FileAppender`. Record shape per LLD §4.2: `ts`, `mode`, `whisper_avg_logprob`, `chosen_skill_id`, `routing_logprob_mean`, `param_validation`, `risk_tier`, `scanner_verdict`, `action_taken`, `user_outcome`, `latency_ms`.
- `CalibrationRecord` — the Codable struct for one log line.
- The `VoiceSessionCoordinator` (P1) and Overlay continue to work unchanged — the new driver produces `VoiceSessionUpdate` events with routing results in the `.result` summary, and the Overlay renders them through the existing state machine.
- Update `docs/07-implementation-pillars.md` to mark P4 as complete.

### Acceptance criteria

- [ ] `CommandModeDriver` with `MockLLMClient` + `MockSTTEngine` + mock scanner + mock skills: transcript "open Safari" → routes to `open_application` → executes → delivers `.result` with success summary
- [ ] `CommandModeDriver`: transcript that routes to `null` → delivers `.result` with prompt-back summary
- [ ] `CommandModeDriver`: transcript that routes to a `confirm`-tier skill with marginal confidence → delivers `.result` with confirm-back summary
- [ ] `CommandModeDriver`: scanner Hard-Block → delivers `.result` with blocked summary
- [ ] `CalibrationRecord` encodes to the expected JSONL shape
- [ ] `CalibrationLogger` appends records to the file (tested with injected temp path)
- [ ] `CalibrationLogger` records include `whisper_avg_logprob`, `routing_logprob_mean`, `chosen_skill_id`, `risk_tier`, `scanner_verdict`, `action_taken`
- [ ] Existing `VoiceSessionCoordinator` tests still pass (the seam contract is unchanged)
- [ ] Existing `STTVoiceSessionDriver` tests still pass (dictation mode path unchanged)
- [ ] Module registered in `Package.swift`; `just check` passes
- [ ] `docs/07-implementation-pillars.md` updated to show P4 status
