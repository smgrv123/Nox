# Plan: P5a · Dictation Core

> Source PRD: [`specs/P5a-dictation-core.md`](../specs/P5a-dictation-core.md)
> Depends on: P1, P2a, P2b, P3, P4 — all complete on `main` (`f71cd9b` at plan authorship).
> Grounded in: HLD §9, §18.2; LLD §2.5, §3.5, §4.6, §4.7, §6.3, §8–10.
> Execution: `/execute-plan --tdd`, **one phase at a time**, TDD vertical slices.
>
> **Explicitness override.** The `prd-to-plan` template says not to name files. The user instructed: *leave no part of the work another agent will do to guess.* This plan names modules, signatures, constants, registration, and tests. Do not generalize it.
>
> **Status: all 5 phases complete.** Read the amendment below before treating any signature
> here as current.

## Amendment — AX insertion removed (post-implementation)

Phases 1–5 shipped, but **AX insertion was reversed during Phase 5 hardening**; insertion is
now **paste-only**. See ADR **A8** in [`docs/03-architecture.md`](../docs/03-architecture.md)
and the matching amendment in the PRD. `AXUIElementSetAttributeValue(…, kAXSelectedTextAttribute, …)`
returns `.success` on *acceptance*, not insertion — Electron, Catalyst and custom text views
accept and discard it. Zero confirmed successes across WhatsApp, Messages, VS Code, Ghostty
and Finder, and its false success suppressed the paste fallback, silently losing the utterance.

**Deleted:** `Sources/Dictation/InsertionPlanner.swift`,
`Sources/Dictation/TerminalBundleAllowlist.swift`, `Sources/AideCore/InsertionOverride.swift`,
`Tests/DictationTests/InsertionPlannerTests.swift`,
`Tests/DictationTests/TerminalBundleAllowlistTests.swift`, and the
`settings.text_insertion` block.

**Current `TextInserting`:**

```swift
public enum InsertionFailure: Equatable, Sendable {
    case secureInput
    case pasteFailed(detail: String)
}

public enum InsertionResult: Equatable, Sendable {
    case insertedViaPaste
    case failed(InsertionFailure)
    case copiedToClipboard
}

@MainActor
public protocol TextInserting: AnyObject {
    func resolveFocus() async -> InsertionFocus
    func insert(_ text: String) async -> InsertionResult
    func copyToClipboard(_ text: String) async
}
```

**Other departures from this plan, all deliberate and user-approved:**

| Planned | Shipped | Why |
|---|---|---|
| `peakNormalize` copied privately (Phase 1, and an explicit PRD non-goal) | Whole capture→transcribe→Pre-Gate front half extracted to `SpeechToText.CaptureTranscribeGate`, shared with `STTVoiceSessionDriver` | Code-review finding. Placed in `SpeechToText` (both dependents already import it) so no pillar seam is crossed |
| Paste settle 80ms (PROVISIONAL) | **400ms** | 80ms was never tuned; a loaded app easily exceeds it. 300–500ms is the sane band |
| `SamplingParams(temperature: 0.2, topP: 1.0, maxTokens: 1024, topLogprobs: 0)` | Same, plus `disableThinking: true` → `chat_template_kwargs: {"enable_thinking": false}` | Qwen3 hybrid reasoning is on by default. Measured 27.35s → 1.79s on identical input |
| Cleanup runs, then terminal scan on the transcript | Cleanup **skipped** for terminal destinations; scan runs on the exact string about to be inserted | Scanning text the model may have rewritten is the wrong string to scan |
| Confirm-Back has no timeout | 10s timeout that **copies to clipboard** | Timeout originally called `reject()`, silently destroying the text |
| No timing capture | Six optional timing fields on `DictationHistoryEntry` (`audio_ms`, `stt_ms`, `model_load_ms`, `cleanup_ms`, `insert_ms`, `total_ms`); `InsertionKind.ax` retained for backward-compatible decoding of old history lines | Measure latency rather than guess at it |
| — | Secure-Input preflight; nspasteboard concealed/transient markers; "Copy Last Dictation" menubar item | Added during the AX reversal |

## Architectural decisions

Durable across all phases:

- **Branch:** `feat/p5a-dictation-core`. All P5a and P5b phases stay on this branch. No per-phase branches or worktrees.
- **New SwiftPM module `Dictation`** at `Sources/Dictation/`, tests at `Tests/DictationTests/`. Register **product + target + testTarget** in `Package.swift`, add `product: Dictation` under `targets.Aide.dependencies` in `project.yml`, then `just gen`.
- **Dependencies of `Dictation`:** `AideCore`, `SpeechToText`, `LLMRuntime`, `DangerousCommandScanner`. **Forbidden:** AppKit, ApplicationServices, `InferenceClient`, `CommandMode`, `BuiltinSkills`.
- **Seam swap (only wiring change to the mux):** `App/AppCoordinator+CommandMode.swift` `setUpCommandMode()` — replace `STTVoiceSessionDriver` assigned to `dictation` with `DictationDriver`. Do **not** edit `App/MuxVoiceSessionDriver.swift`, `VoiceSessionCoordinator`, or Overlay state machines.
- **`TextInserting` protocol** (in `Dictation`, not AideCore):

  ```swift
  public struct InsertionFocus: Equatable, Sendable {
      public var bundleID: String?
      public var accessibilityTrusted: Bool
  }

  public enum InsertionFailure: Equatable, Sendable {
      case secureInput
      case pasteFailed(detail: String)
  }

  public enum InsertionResult: Equatable, Sendable {
      case insertedViaPaste
      case failed(InsertionFailure)
      case copiedToClipboard
  }

  @MainActor
  public protocol TextInserting: AnyObject {
      func resolveFocus() async -> InsertionFocus
      func insert(_ text: String) async -> InsertionResult
      func copyToClipboard(_ text: String) async
  }
  ```

  *As-built. The plan originally specified `AppInsertionOverride` / `InsertionPlan` / `insert(_:plan:)` — see the amendment above.*

- **~~`InsertionPlanner`~~:** Deleted with AX reversal; one insertion path (paste) leaves nothing to plan.
- **Terminal IDs:** promote `ScanRuleEngine.terminalBundleIDs` to `public` (e.g. `public enum TerminalBundleIDs { public static let allowlist: Set<String> }` on `DangerousCommandScanner`). ~~`Dictation.TerminalBundleAllowlist.contains` delegates to it. Test: the two sets are equal — actually they **are** the same set; the test is `TerminalBundleAllowlist.ids == TerminalBundleIDs.allowlist`~~ The driver now reads the scanner's public `allowlist` directly, removing the divergence risk. Seven terminal IDs: `com.apple.Terminal`, `com.googlecode.iterm2`, `dev.warp.Warp-Stable`, `com.mitchellh.ghostty`, `net.kovidgoyal.kitty`, `org.alacritty`, `com.github.wez.wezterm`.
- **Cleanup bypass (Phase 4):** `Settings.Dictation.cleanupEnabled` default `true`. Sidecar **not** `.ready` → insert raw immediately; Overlay summary **exactly** `Inserted raw — language model wasn't ready.` Do **not** await the 45s `resolveLiveSidecarEndpoint` path. Optional background `startIfNeeded`. Modifier-key bypass is forbidden.
- **Settings v6:** add `tone`, `dictation` ~~, `text_insertion`~~ blocks; `currentSchemaVersion = 6`; `SettingsMigration(from: 5, to: 6)`. Schema still bumps to v6 for `tone` + `dictation` alone.
- **Confirm-Back:** `ConfirmBackInfo(transcript:text, intent:text, skillID: "dictation_insert", riskTier: .alwaysConfirm)`.
- **P5b slots on `DictationDriver`:** `makeInitialPrompt: @Sendable () async -> String? = { nil }` and `dictionarySubstitutions: @Sendable () async -> String = { "" }`.
- **Peak normalize:** ~~copy `STTVoiceSessionDriver.peakNormalize` privately. Do not extract.~~ Whole capture→transcribe→Pre-Gate front half extracted to `SpeechToText.CaptureTranscribeGate`, shared with `STTVoiceSessionDriver` (code-review finding). Placed in `SpeechToText` because both dependents already import it, so no pillar seam is crossed.
- **LLM cleanup:** `SamplingParams(temperature: 0.2, topP: 1.0, maxTokens: 1024, topLogprobs: 0, disableThinking: true)`, `stream: false`, local endpoint only. Maps to `chat_template_kwargs: {"enable_thinking": false}` (Qwen3 hybrid reasoning is on by default; measured 27.35s → 1.79s).
- **Paste settle:** 400ms in `TextInserterLive` only. Originally 80ms (PROVISIONAL, never tuned); ⌘V only queues the keystroke and the target app reads the pasteboard on its own schedule, so 300–500ms is the sane band.
- **Testing:** TDD, one test → one impl. Pattern: `Tests/STTVoiceSessionTests`.
- **Per-phase gate (MUST):** `just check` **and** `just app` **and** SwiftLint 0 warnings. `swift build` / `just check` **do not compile `App/`**. After commit, run `just check` again (pre-commit strict-lints but does not fail on format). Never `--no-verify`. Never `--amend`.

---

## Phase 1: Raw insertion tracer bullet

**User stories**: 1, 2, 3, 4, 5, 6, 24, 25

### What to build

Hold ⌃Space → transcribe → insert **raw** text at the caret. No cleanup, no terminal scan, no Settings.

1. Register `Dictation` in `Package.swift` (library + target deps `AideCore`, `SpeechToText`; test target) and `project.yml`; `just gen`.
2. `Sources/Dictation/TextInserting.swift` — types + protocol above. `copyToClipboard` may empty-default via protocol extension.
3. ~~`Sources/Dictation/InsertionPlanner.swift` — default `.axThenPaste`; override `.paste` → `.pasteOnly`; override `.ax` → `.axOnly`. `isTerminal` unused.~~ Not shipped; deleted with AX reversal — see amendment above.
4. `Sources/Dictation/DictationDriver.swift` — copy structure from `Sources/STTVoiceSession/STTVoiceSessionDriver.swift` (generation, captureTask, begin/end/cancel, Pre-Gate, peakNormalize, degraded summaries). Differences:
   - `init(engine:capture:preGate:inserter:)` ~~`overrides:` where `overrides: @Sendable () -> [String: AppInsertionOverride] = { [:]}`~~ (parameter deleted with AX reversal).
   - `transcribe(..., initialPrompt: await makeInitialPrompt())` (nil for now).
   - On Pre-Gate `.pass`: `resolveFocus()` → `insert`; then `onUpdate(.transcript)` and `.result(VoiceSessionResult(transcript:text, summary:text))`.
   - On insert `.failed`: still deliver transcript; summary is the failure reason (do not swallow).
   - Do **not** call LLM. Do **not** scan.
5. `App/TextInserterLive.swift` — `@MainActor`. `resolveFocus`: `AXIsProcessTrusted()` + `NSWorkspace.shared.frontmostApplication?.bundleIdentifier` (AX status still required for synthetic ⌘V). `insert`: Secure-Input preflight via `IsSecureEventInputEnabled()` (Carbon) **before** touching the pasteboard; snapshot all pasteboard types via `pasteboardItems` / type-data map; `clearContents()`; write one `NSPasteboardItem` carrying the string plus `org.nspasteboard.ConcealedType` and `org.nspasteboard.TransientType` markers in one `writeObjects` batch; CGEvent ⌘V keyDown/keyUp to `.cghidEventTap`; `Task.sleep` 400ms; restore snapshot **even on failure**. Requires import ApplicationServices + AppKit.
6. Wire in `setUpCommandMode()`: construct `DictationDriver` with the **same** `engine`/`capture`/`preGate` instances already built for command mode (one Whisper context, one mic). Pass `TextInserterLive()`.

### Named tests (`Tests/DictationTests/`)

- ~~`InsertionPlannerTests.testDefaultPlanIsAXThenPaste`~~ Removed with module.
- ~~`InsertionPlannerTests.testPasteOverride`~~ Removed with module.
- ~~`InsertionPlannerTests.testAXOverride`~~ Removed with module.
- `DictationDriverTests.testPassInsertsRawTranscript` — `MockSTTEngine` + fake capture (copy `STTVoiceSessionTests` fake) + `RecordingInserter`; assert `insert` called once with the Pre-Gate text; `chat` N/A.
- `DictationDriverTests.testPreGateFailDoesNotInsert`
- `DictationDriverTests.testCancelSuppressesInsert`
- `DictationDriverTests.testMicrophoneFailureDoesNotInsert` — reuse `STTVoiceSessionDriver.microphoneUnavailableSummary` **or** duplicate the three degraded strings on `DictationDriver` as `public static` (prefer **duplicate the three constants** on `DictationDriver` so STTVoiceSession isn't a runtime dep; copy the string values exactly:
  - `"I didn't catch that — try again."`
  - `"Speech model isn't ready yet."`
  - `"Couldn't access the microphone."`)

Do **not** unit-test `TextInserterLive`.

### Acceptance criteria

- [x] `Dictation` module + tests registered; `just gen` run after `project.yml` change.
- [x] Named tests above exist and pass via `swift test`.
- [x] Mux dictation inner driver is `DictationDriver`; command path unchanged.
- [x] `TextInserterLive` compiles in the app target (`just app`).
- [x] Manual: hold ⌃Space in TextEdit, speak, raw text at caret (or Overlay-only if AX not granted — then paste fallback should still land).
- [x] Per-phase gate green.

---

## Phase 2: Terminal-destination safety scan

**User stories**: 7, 8, 9

### What to build

Before inserting, if `TerminalBundleIDs.allowlist.contains(bundleID)`, scan:

```
scanner.scan(text, context: ScanContext(channel: .dictatedOneOff, destinationBundleID: bundleID, manifestID: nil))
```

Use `DangerousCommandScanner()` (the struct). Inject `any CommandScanning` into `DictationDriver` for tests.

- `.clean` → insert as Phase 1.
- `.confirm(findings)` → stash pending text; `onUpdate(.confirmBack(ConfirmBackInfo(... skillID: "dictation_insert", riskTier: .alwaysConfirm)))`. **Zero characters inserted.**
- `.hardBlock` → `onUpdate(.hardBlocked(text, findings.first?.explanation ?? "Blocked"))`. Never insert. No approve path.

`approve()`: insert stashed text; deliver `.result`. `reject()`: drop stash; deliver `.result` with summary `"Cancelled."`.

C11 already confirms **any** dictatedOneOff into a terminal bundle (existing `applyC11Dictation`). Do **not** weaken that test. Additional H-rules still apply to the dictated string.

Promote terminal IDs to public as specified above. `Dictation` may now depend on `DangerousCommandScanner` (add to `Package.swift` target deps).

Overlay already has Confirm-Back buttons (`overlay.onApprove` / `onReject` already wired to the mux). Mux already forwards `approve()`/`reject()`. Implement them on `DictationDriver`.

### Named tests

- ~~`TerminalBundleAllowlistTests.testMatchesScannerAllowlist`~~ Removed with wrapper.
- `DictationDriverTests.testTerminalConfirmDoesNotInsertUntilApprove`
- `DictationDriverTests.testApproveInsertsStashedText`
- `DictationDriverTests.testRejectDoesNotInsert`
- `DictationDriverTests.testHardBlockNeverInserts` — fake scanner returns `hardBlock`.
- `DictationDriverTests.testNonTerminalDoesNotScan` — recording scanner `scan` count 0 when bundle ID is `com.apple.TextEdit`.

Keep existing `Tests/DangerousCommandScannerTests` C11 cases green; do not edit them to pass.

### Acceptance criteria

- [x] Named tests pass.
- [x] Scanner C11 corpus still green.
- [x] Manual: dictating into Terminal shows Confirm-Back; Approve pastes/inserts; Reject leaves the prompt unchanged.
- [x] Per-phase gate green.

---

## Phase 3: Tone-aware cleanup pass

**User stories**: 10, 13, 14, 26

### What to build

Insert *cleaned* text. Default preset `as_is`. No Settings pane yet — pass `TonePreset.asIs` into the driver (`var tonePreset: @Sendable () -> TonePreset`).

Files:

- `Sources/Dictation/TonePreset.swift` — enum `asIs = "as_is"`, `professional`, `casual`, `concise`. `instruction: String` matches LLD §4.6 table (copy essence verbatim).
- `Sources/Dictation/CleanupPromptBuilder.swift` — render LLD §6.3. Placeholders: `TONE_PRESET_INSTRUCTION`, `DICTIONARY_SUBSTITUTIONS` (from `dictionarySubstitutions()`; if empty, the "Apply these known corrections" block should read `none.` so the model isn't looking at a blank list), `RAW_TRANSCRIPT`.
- `Sources/Dictation/CleanupResponseSanitizer.swift` — `static func sanitize(_ raw: String) -> String`. Trim; strip one layer of wrapping `"` or `""";` drop a prefix if it case-insensitively matches any of: `Here is the cleaned text:`, `Here's the cleaned text:`, `Cleaned text:`, `Sure,`, `Certainly,`. Do **not** invent an LLM "did it add facts" detector.
- `DictationDriver`: after Pre-Gate pass (and after Phase 2 scan allows insert), Phase 3 assumes a `resolveEndpoint: @Sendable () async throws -> LLMEndpoint` **plus** `llm: any LLMClient`. Cleanup is **three-state**: `cleaned` / `skipped` / `chatFailed`. Handle **resolve separately from chat** — not one `catch` for both. If `resolveEndpoint` throws **or** `endpoint.isLocal` is false, **skip** cleanup and insert raw; Overlay summary is the inserted text (Phase 4 will distinguish "not ready" copy). Temperature 0.2, stream false. Sanitize. Insert sanitized. If `llm.chat` throws **or** stream iteration throws, insert raw and summary `"Inserted raw — cleanup failed."` (`DictationDriver.cleanupFailedSummary`).
- Guard `endpoint.isLocal` before chat; if not local, insert raw (must never implicitly offload) — same **skip** path as resolve throw, not `chatFailed`.

Add `LLMRuntime` to the `Dictation` target deps.

### Named tests

- `TonePresetTests.testAsIsInstructionMentionsPreserveWording`
- `CleanupPromptBuilderTests.testIncludesRawTranscriptAndTone`
- `CleanupPromptBuilderTests.testEmptySubstitutionsRenderNone`
- `CleanupResponseSanitizerTests.testStripsQuotedModelPreamble`
- `CleanupResponseSanitizerTests.testLeavesCleanTextAlone`
- `DictationDriverTests.testCleanupInsertsSanitizedText` — `MockLLMClient.setChatChunks(.success([ChatCompletionChunk(delta:"Cleaned.", isFinal:true)]))`; inserter sees `"Cleaned."`; `chatCallCount == 1`; `SamplingParams.temperature == 0.2` — assert via a recording LLM wrapper if `MockLLMClient` doesn't record params; **extend `MockLLMClient` in LLMRuntime** with `lastSamplingParams: SamplingParams?` (small, justified).
- `DictationDriverTests.testCleanupFailureInsertsRaw` — `llm.chat` throws; insert raw; Overlay summary exactly `Inserted raw — cleanup failed.`
- `DictationDriverTests.testResolveEndpointFailureInsertsRaw` — `resolveEndpoint` throws; insert raw; Overlay summary is the transcript (skip, not chat-failed).
- `DictationDriverTests.testNonLocalEndpointSkipsCleanup`

### Acceptance criteria

- [x] Named tests pass.
- [x] Manual: with sidecar already warm, dictation in TextEdit inserts cleaned (filler dropped) text.
- [x] Per-phase gate green.

---

## Phase 4: Tone presets, Settings, raw bypass

**User stories**: 11, 12, 15, 16, 17, 18, 19

### What to build

**Settings schema v6** in `Sources/Configuration/Settings.swift`:

- `currentSchemaVersion = 6`
- Nested `Settings.Tone` (`defaultPreset: TonePreset` stored as String to avoid Configuration→Dictation dependency — use `String` raw values `as_is` etc., default `"as_is"`; `available` is not persisted as user-editable, omit from the model or persist as read-only default list).
- Nested `Settings.DictationBlock` — **name it `DictationSettings`** (`cleanupEnabled: Bool = true`) to avoid clashing with the module name at import sites. JSON key `dictation`.
- ~~Nested `Settings.TextInsertion` (`appOverrides: [String: AppInsertionOverride]`). Configuration cannot import Dictation — duplicate the `ax`/`paste` enum **inside Configuration** as `Settings.InsertionOverride` (`String` raw values `ax`/`paste`). Dictation's `AppInsertionOverride` should match raw values; map at the app boundary. **Do not** create a module cycle.~~ Not shipped; deleted with AX reversal.

`SettingsMigration` v5→v6: if keys absent, do not invent huge blobs; tolerant decode supplies defaults. Still bump `schema_version` to 6.

`Tests/ConfigurationTests`: add `SettingsMigrationV6Tests` (v5 fixture without the new blocks loads as v6 with defaults; a file that already has `tone.default_preset: professional` keeps it). Update any test that hardcoded `schema_version == 5`.

**`TonePrefixParser`:** `struct TonePrefixParser { func parse(_ transcript: String) -> (preset: TonePreset?, remainder: String) }`. Match leading `(as-is|as is|professional|casual|concise)\s*tone\s*:` case-insensitive. Remainder is the text to clean/insert. If no match, `(nil, original)`.

**Driver bypass:**

- Read `cleanupEnabled` via injected `() -> Bool`.
- `sidecarReady: () async -> Bool` — App layer: `sidecarManagerInstance` state == `.ready` **without** starting it. If false: skip chat, insert raw (after prefix strip), summary **exactly** `Inserted raw — language model wasn't ready.` unless cleanup is disabled, in which case summary is the inserted text (user asked for raw).
- If cleanup disabled: never chat; summary is the (prefix-stripped) text.
- Voice prefix overrides `settings.tone.defaultPreset` for this utterance only.

**`App/Settings/DictationPane.swift`:** default tone picker (four presets), cleanup toggle~~, read-only list of `app_overrides` (empty-state "No app overrides yet")~~. Register in `SettingsRootView.panes` as `id: "dictation", title: "Dictation", systemImage: "mic"`.

**App wiring:** pass settings closures into `DictationDriver` from `AppCoordinator` (main-actor settings store).

### Named tests

- `TonePrefixParserTests.testProfessionalTonePrefix`
- `TonePrefixParserTests.testPrefixIsCaseInsensitive`
- `TonePrefixParserTests.testMidSentenceToneIsIgnored`
- `DictationDriverTests.testCleanupDisabledSkipsLLM`
- `DictationDriverTests.testSidecarNotReadyInsertsRawWithExactSummary`
- `DictationDriverTests.testPrefixSelectsProfessionalInstruction` — recording prompt builder or inspect `MockLLMClient` last user message contains professional essence.
- Configuration v6 tests as above.

### Acceptance criteria

- [x] v5 settings files migrate; hotkeys preserved.
- [x] Named tests pass.
- [x] Dictation pane visible in Settings.
- [x] Manual: cleanup off → raw with sidecar warm; cleanup on + quit sidecar / before first load → raw with the exact Overlay summary.
- [x] Per-phase gate green.

---

## Phase 5: Degradation + per-app override learning

**User stories**: 20, 21, 22, 23

### What to build

- **Accessibility denied:** If `!focus.accessibilityTrusted`, Overlay summary **exactly** `Text insertion needs Accessibility. Enable Aide in System Settings.` The Permissions pane already deep-links; do not invent new Overlay buttons.
- **Paste failed or Secure Input active:** `InsertionResult.failed` after both paths: `copyToClipboard(text)` then summary **exactly** `Couldn't insert — copied to clipboard instead.`
- **Per-app override learning:** Deleted with AX reversal. One insertion path (paste) means no per-app divergence to learn.
- **History:** `struct DictationHistoryEntry: Codable` in `Dictation`. Fields: `ts`, `mode: "dictation"`, `transcript`, `cleaned` (optional), `cleanup_ran: Bool`, `insertion`, `destination_bundle_id`, plus optional timing fields (added later): `audio_ms`, `stt_ms`, `model_load_ms`, `cleanup_ms`, `insert_ms`, `total_ms`. Append via `HistoryLog` to `storage.historyFile(for:)`. Swallow errors (`try?`) so log failure cannot block insert. `InsertionKind.ax` retained **only** for backward-compatible decoding of history lines written before AX reversal.

### Named tests

- `DictationDriverTests.testBothPathsFailedCopiesToClipboard` — paste failed escape.
- ~~`DictationDriverTests.testPasteFallbackRecordsOverrideOnce`~~ Removed with override learning.
- ~~`DictationDriverTests.testExistingPasteOverrideDoesNotRescanAX`~~ Removed with override learning.
- `DictationHistoryEntryTests.testJSONKeysSnakeCase` — `destination_bundle_id`, `cleanup_ran`.

### Acceptance criteria

- [x] Named tests pass.
- [x] Manual: paste verified in Messages, Ghostty and Dia; Secure Input and paste failure both fall back to the clipboard copy escape; `history/commands-*.jsonl` has a dictation line with timings.
- [x] Per-phase gate green.

---

## Execution notes

- Phases are **strictly sequential** (each driver change stacks).
- P5b Phase 1 (store) is independent of P5a and *may* run after P5a Phase 1 on the same branch if a later batch is approved to parallelize; **P5b Phase 4 (substitution injection) requires P5a Phase 3.** Default execution: **all of P5a, then all of P5b**.
- After each phase: code-review (Standards + Spec vs this plan + PRD), review-refactor for findings, commit, then next phase.
- Do not absorb deferred P4 bugs.
