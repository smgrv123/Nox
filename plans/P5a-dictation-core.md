# Plan: P5a · Dictation Core

> Source PRD: [`specs/P5a-dictation-core.md`](../specs/P5a-dictation-core.md)
> Depends on: P1, P2a, P2b, P3, P4 — all complete on `main` (`f71cd9b` at plan authorship).
> Grounded in: HLD §9, §18.2; LLD §2.5, §3.5, §4.6, §4.7, §6.3, §8–10.
> Execution: `/execute-plan --tdd`, **one phase at a time**, TDD vertical slices.
>
> **Explicitness override.** The `prd-to-plan` template says not to name files. The user instructed: *leave no part of the work another agent will do to guess.* This plan names modules, signatures, constants, registration, and tests. Do not generalize it.

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

  public enum AppInsertionOverride: String, Equatable, Sendable, Codable {
      case ax
      case paste
  }

  public enum InsertionPlan: Equatable, Sendable {
      case axThenPaste
      case axOnly
      case pasteOnly
  }

  public enum InsertionResult: Equatable, Sendable {
      case insertedViaAX
      case insertedViaPaste
      case failed(reason: String)
      case copiedToClipboard   // Phase 5 escape
  }

  @MainActor
  public protocol TextInserting: AnyObject {
      func resolveFocus() async -> InsertionFocus
      func insert(_ text: String, plan: InsertionPlan) async -> InsertionResult
      func copyToClipboard(_ text: String) async  // Phase 5; can no-op stub earlier
  }
  ```

  **No `AXUIElement` in this module** (LLD §3.5 deviation, documented in the PRD).

- **`InsertionPlanner`:** `func plan(focus: InsertionFocus, override: AppInsertionOverride?, isTerminal: Bool) -> InsertionPlan`. Phase 1 ignores `isTerminal`. Phase 2 still returns an insert plan; **scanning is the driver's job** (planner does not call the scanner). `isTerminal` may force the driver to scan before executing whatever plan is returned.
- **Terminal IDs:** promote `ScanRuleEngine.terminalBundleIDs` to `public` (e.g. `public enum TerminalBundleIDs { public static let allowlist: Set<String> }` on `DangerousCommandScanner`). `Dictation.TerminalBundleAllowlist.contains` delegates to it. Test: the two sets are equal — actually they **are** the same set; the test is `TerminalBundleAllowlist.ids == TerminalBundleIDs.allowlist` and a corpus of the seven IDs from `ScanRuleEngine.swift` today: `com.apple.Terminal`, `com.googlecode.iterm2`, `dev.warp.Warp-Stable`, `com.mitchellh.ghostty`, `net.kovidgoyal.kitty`, `org.alacritty`, `com.github.wez.wezterm`.
- **Cleanup bypass (Phase 4):** `Settings.Dictation.cleanupEnabled` default `true`. Sidecar **not** `.ready` → insert raw immediately; Overlay summary **exactly** `Inserted raw — language model wasn't ready.` Do **not** await the 45s `resolveLiveSidecarEndpoint` path. Optional background `startIfNeeded`. Modifier-key bypass is forbidden.
- **Settings v6:** add `tone`, `dictation`, `text_insertion` blocks; `currentSchemaVersion = 6`; `SettingsMigration(from: 5, to: 6)`.
- **Confirm-Back:** `ConfirmBackInfo(transcript:text, intent:text, skillID: "dictation_insert", riskTier: .alwaysConfirm)`.
- **P5b slots on `DictationDriver`:** `makeInitialPrompt: @Sendable () async -> String? = { nil }` and `dictionarySubstitutions: @Sendable () async -> String = { "" }`.
- **Peak normalize:** copy `STTVoiceSessionDriver.peakNormalize` privately. Do not extract.
- **LLM cleanup:** `SamplingParams(temperature: 0.2, topP: 1.0, maxTokens: 1024, topLogprobs: 0)`, `stream: false`, local endpoint only.
- **Paste settle:** 80ms (PROVISIONAL) in `TextInserterLive` only.
- **Testing:** TDD, one test → one impl. Pattern: `Tests/STTVoiceSessionTests`.
- **Per-phase gate (MUST):** `just check` **and** `just app` **and** SwiftLint 0 warnings. `swift build` / `just check` **do not compile `App/`**. After commit, run `just check` again (pre-commit strict-lints but does not fail on format). Never `--no-verify`. Never `--amend`.

---

## Phase 1: Raw insertion tracer bullet

**User stories**: 1, 2, 3, 4, 5, 6, 24, 25

### What to build

Hold ⌃Space → transcribe → insert **raw** text at the caret. No cleanup, no terminal scan, no Settings.

1. Register `Dictation` in `Package.swift` (library + target deps `AideCore`, `SpeechToText`; test target) and `project.yml`; `just gen`.
2. `Sources/Dictation/TextInserting.swift` — types + protocol above. `copyToClipboard` may empty-default via protocol extension.
3. `Sources/Dictation/InsertionPlanner.swift` — default `.axThenPaste`; override `.paste` → `.pasteOnly`; override `.ax` → `.axOnly`. `isTerminal` unused.
4. `Sources/Dictation/DictationDriver.swift` — copy structure from `Sources/STTVoiceSession/STTVoiceSessionDriver.swift` (generation, captureTask, begin/end/cancel, Pre-Gate, peakNormalize, degraded summaries). Differences:
   - `init(engine:capture:preGate:inserter:overrides:)` where `overrides: @Sendable () -> [String: AppInsertionOverride] = { [:]}`.
   - `transcribe(..., initialPrompt: await makeInitialPrompt())` (nil for now).
   - On Pre-Gate `.pass`: `resolveFocus()` → `InsertionPlanner.plan` → `insert`; then `onUpdate(.transcript)` and `.result(VoiceSessionResult(transcript:text, summary:text))`.
   - On insert `.failed`: still deliver transcript; summary is the failure reason (do not swallow).
   - Do **not** call LLM. Do **not** scan.
5. `App/TextInserterLive.swift` — `@MainActor`. `resolveFocus`: `AXIsProcessTrusted()` + `NSWorkspace.shared.frontmostApplication?.bundleIdentifier`. `insert`: AX path `AXUIElementCreateSystemWide` → focused UI element → `AXUIElementSetAttributeValue(..., kAXSelectedTextAttribute, text as CFTypeRef)`. On AX skip/fail: snapshot `NSPasteboard.general` (all types via `pasteboardItems` / type-data map), `clearContents()`, `setString`, CGEvent ⌘V keyDown/keyUp to `CGEventPost(.cghidEventTap)` or the focused process, `Task.sleep` 80ms, restore snapshot **even if paste threw**. Requires import ApplicationServices + AppKit.
6. Wire in `setUpCommandMode()`: construct `DictationDriver` with the **same** `engine`/`capture`/`preGate` instances already built for command mode (one Whisper context, one mic). Pass `TextInserterLive()`.

### Named tests (`Tests/DictationTests/`)

- `InsertionPlannerTests.testDefaultPlanIsAXThenPaste`
- `InsertionPlannerTests.testPasteOverride`
- `InsertionPlannerTests.testAXOverride`
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
- [ ] Manual: hold ⌃Space in TextEdit, speak, raw text at caret (or Overlay-only if AX not granted — then paste fallback should still land).
- [x] Per-phase gate green.

---

## Phase 2: Terminal-destination safety scan

**User stories**: 7, 8, 9

### What to build

Before inserting, if `TerminalBundleAllowlist.contains(focus.bundleID)`, scan:

```
scanner.scan(text, context: ScanContext(channel: .dictatedOneOff, destinationBundleID: bundleID, manifestID: nil))
```

Use `DangerousCommandScanner()` (the struct). Inject `any CommandScanning` into `DictationDriver` for tests.

- `.clean` → insert as Phase 1.
- `.confirm(findings)` → stash pending text+plan; `onUpdate(.confirmBack(ConfirmBackInfo(... skillID: "dictation_insert", riskTier: .alwaysConfirm)))`. **Zero characters inserted.**
- `.hardBlock` → `onUpdate(.hardBlocked(text, findings.first?.explanation ?? "Blocked"))`. Never insert. No approve path.

`approve()`: insert stashed text; deliver `.result`. `reject()`: drop stash; deliver `.result` with summary `"Cancelled."`.

C11 already confirms **any** dictatedOneOff into a terminal bundle (existing `applyC11Dictation`). Do **not** weaken that test. Additional H-rules still apply to the dictated string.

Promote terminal IDs to public as specified above. `Dictation` may now depend on `DangerousCommandScanner` (add to `Package.swift` target deps).

Overlay already has Confirm-Back buttons (`overlay.onApprove` / `onReject` already wired to the mux). Mux already forwards `approve()`/`reject()`. Implement them on `DictationDriver`.

### Named tests

- `TerminalBundleAllowlistTests.testMatchesScannerAllowlist`
- `DictationDriverTests.testTerminalConfirmDoesNotInsertUntilApprove`
- `DictationDriverTests.testApproveInsertsStashedText`
- `DictationDriverTests.testRejectDoesNotInsert`
- `DictationDriverTests.testHardBlockNeverInserts` — fake scanner returns `hardBlock`.
- `DictationDriverTests.testNonTerminalDoesNotScan` — recording scanner `scan` count 0 when bundle ID is `com.apple.TextEdit`.

Keep existing `Tests/DangerousCommandScannerTests` C11 cases green; do not edit them to pass.

### Acceptance criteria

- [x] Named tests pass.
- [x] Scanner C11 corpus still green.
- [ ] Manual: dictating into Terminal shows Confirm-Back; Approve pastes/inserts; Reject leaves the prompt unchanged.
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
- [ ] Manual: with sidecar already warm, dictation in TextEdit inserts cleaned (filler dropped) text.
- [x] Per-phase gate green.

---

## Phase 4: Tone presets, Settings, raw bypass

**User stories**: 11, 12, 15, 16, 17, 18, 19

### What to build

**Settings schema v6** in `Sources/Configuration/Settings.swift`:

- `currentSchemaVersion = 6`
- Nested `Settings.Tone` (`defaultPreset: TonePreset` stored as String to avoid Configuration→Dictation dependency — use `String` raw values `as_is` etc., default `"as_is"`; `available` is not persisted as user-editable, omit from the model or persist as read-only default list).
- Nested `Settings.DictationBlock` — **name it `DictationSettings`** (`cleanupEnabled: Bool = true`) to avoid clashing with the module name at import sites. JSON key `dictation`.
- Nested `Settings.TextInsertion` (`appOverrides: [String: AppInsertionOverride]`). Configuration cannot import Dictation — duplicate the `ax`/`paste` enum **inside Configuration** as `Settings.InsertionOverride` (`String` raw values `ax`/`paste`). Dictation's `AppInsertionOverride` should match raw values; map at the app boundary. **Do not** create a module cycle.

`SettingsMigration` v5→v6: if keys absent, do not invent huge blobs; tolerant decode supplies defaults. Still bump `schema_version` to 6.

`Tests/ConfigurationTests`: add `SettingsMigrationV6Tests` (v5 fixture without the new blocks loads as v6 with defaults; a file that already has `tone.default_preset: professional` keeps it). Update any test that hardcoded `schema_version == 5`.

**`TonePrefixParser`:** `struct TonePrefixParser { func parse(_ transcript: String) -> (preset: TonePreset?, remainder: String) }`. Match leading `(as-is|as is|professional|casual|concise)\s*tone\s*:` case-insensitive. Remainder is the text to clean/insert. If no match, `(nil, original)`.

**Driver bypass:**

- Read `cleanupEnabled` via injected `() -> Bool`.
- `sidecarReady: () async -> Bool` — App layer: `sidecarManagerInstance` state == `.ready` **without** starting it. If false: skip chat, insert raw (after prefix strip), summary **exactly** `Inserted raw — language model wasn't ready.` unless cleanup is disabled, in which case summary is the inserted text (user asked for raw).
- If cleanup disabled: never chat; summary is the (prefix-stripped) text.
- Voice prefix overrides `settings.tone.defaultPreset` for this utterance only.

**`App/Settings/DictationPane.swift`:** default tone picker (four presets), cleanup toggle, read-only list of `app_overrides` (empty-state "No app overrides yet"). Register in `SettingsRootView.panes` as `id: "dictation", title: "Dictation", systemImage: "mic"`.

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

- [ ] v5 settings files migrate; hotkeys preserved.
- [ ] Named tests pass.
- [ ] Dictation pane visible in Settings.
- [ ] Manual: cleanup off → raw with sidecar warm; cleanup on + quit sidecar / before first load → raw with the exact Overlay summary.
- [ ] Per-phase gate green.

---

## Phase 5: Degradation + per-app override learning

**User stories**: 20, 21, 22, 23

### What to build

- If `!focus.accessibilityTrusted` and override isn't `.paste`: Overlay `.result` summary **exactly** `Text insertion needs Accessibility. Enable Aide in System Settings.` and still **attempt paste fallback** (paste does not require AX for the clipboard, but synthetic ⌘V often still needs AX — if paste also fails, go to copy escape). Deep-link affordance: include the existing Accessibility deep-link in menubar/Settings; Overlay text does not need a button if Overlay has no generic action slot — do **not** invent Overlay buttons. The Permissions pane already deep-links.
- `InsertionResult.failed` after both paths: `copyToClipboard(text)` then summary **exactly** `Couldn't insert — copied to clipboard instead.`
- On `.insertedViaPaste` when the plan was `.axThenPaste` (AX was tried and failed): persist `settings.text_insertion.app_overrides[bundleID] = "paste"` via an injected `recordOverride: (String, AppInsertionOverride) -> Void`. Do **not** record when the user already had a paste override or when plan was `.pasteOnly` from the start.
- **History:** `struct DictationHistoryEntry: Codable` in `Dictation` (or Persistence if it must live with command history). Fields: `ts`, `mode: "dictation"`, `transcript`, `cleaned` (optional), `cleanupRan: Bool`, `insertion` (ax/paste/failed/copied), `destinationBundleID`. Append with `HistoryLog` to `storage.historyFile(for:)`. Swallow append errors (`try?`) so a log failure cannot block insert; `AideError.storage` is not required if Overlay already showed success.

### Named tests

- `DictationDriverTests.testBothPathsFailedCopiesToClipboard`
- `DictationDriverTests.testPasteFallbackRecordsOverrideOnce`
- `DictationDriverTests.testExistingPasteOverrideDoesNotRescanAX` — planner given `.paste` → inserter `insert` called with `.pasteOnly` only.
- `DictationHistoryEntryTests.testJSONKeysSnakeCase` — `destination_bundle_id`, `cleanup_ran`.

### Acceptance criteria

- [ ] Named tests pass.
- [ ] Manual: AX off → honest Overlay + paste or copy escape; VS Code paste success writes override; Settings pane shows it; `history/commands-*.jsonl` has a dictation line.
- [ ] Per-phase gate green.

---

## Execution notes

- Phases are **strictly sequential** (each driver change stacks).
- P5b Phase 1 (store) is independent of P5a and *may* run after P5a Phase 1 on the same branch if a later batch is approved to parallelize; **P5b Phase 4 (substitution injection) requires P5a Phase 3.** Default execution: **all of P5a, then all of P5b**.
- After each phase: code-review (Standards + Spec vs this plan + PRD), review-refactor for findings, commit, then next phase.
- Do not absorb deferred P4 bugs.
