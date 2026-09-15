# PRD — P5a · Dictation Core

> First of the two verticals **P5 · Dictation** (see [`docs/07-implementation-pillars.md`](../docs/07-implementation-pillars.md)) is split into:
> **P5a · Dictation Core** (this doc) and **P5b · Personalization Dictionary** (spec'd next).
> Grounded in [`docs/04-hld.md`](../docs/04-hld.md) §9, §18.2 and [`docs/05-lld.md`](../docs/05-lld.md) §2.5, §3.5, §4.6, §4.7, §6.3, §8, §9, §10.
> Status: **implemented** · planned in [`plans/P5a-dictation-core.md`](../plans/P5a-dictation-core.md).

## Amendment — AX insertion removed (post-implementation)

This PRD was written before implementation and specifies **AX-first insertion with a
clipboard-paste fallback**. That design was tried, measured, and **reversed**; the shipped
pillar is **paste-only**. See ADR **A8** in [`docs/03-architecture.md`](../docs/03-architecture.md),
HLD §9.4, and LLD §3.5 / §4.7 for the current design.

**Why:** `AXUIElementSetAttributeValue(…, kAXSelectedTextAttribute, …)` returns `.success`
when the attribute write is *accepted*, not when text is actually inserted. Electron,
Catalyst, and custom text views accept and discard it. Across WhatsApp, Messages
(`com.apple.MobileSMS`, native/Catalyst), VS Code, Ghostty and Finder, AX had **zero
confirmed successes** — and its false success suppressed the paste fallback, so the
utterance vanished silently. That is strictly worse than not trying AX at all.

**Superseded by this amendment** (everything below that describes them is historical):

| In this PRD | Now |
|---|---|
| AX-first insertion, paste as fallback | Paste-only (synthetic ⌘V) |
| `InsertionPlan`, `AppInsertionOverride`, `InsertionPlanner` | Deleted — there is one path, nothing to plan |
| `TerminalBundleAllowlist` wrapper | Deleted — the driver calls the scanner's public set directly |
| `settings.text_insertion.app_overrides` + override learning (story 22) | Deleted — no per-app divergence left to learn |
| `TextInserting.insert(_:plan:)` | `insert(_:)` |
| `InsertionResult.insertedViaAX` | Gone; `.failed(reason: String)` is now `.failed(InsertionFailure)` (`.secureInput` / `.pasteFailed`) |
| Accessibility-denied degradation (story 20) | Still required — synthetic ⌘V needs Accessibility just as the AX write did |

**Added during implementation, not in this PRD:**

- **Secure-Input preflight** — `IsSecureEventInputEnabled()` is checked *before* touching the
  pasteboard. When macOS Secure Input is on, synthetic keystrokes are silently discarded, so
  ⌘V can never land; detecting it first means Aide reports failure without clobbering the
  user's clipboard for a paste that was never going to work.
- **Clipboard-manager skip markers** — each dictated item carries
  `org.nspasteboard.ConcealedType` / `TransientType` (the nspasteboard.org convention) so
  Raycast, Maccy, Alfred et al. skip recording it. Every dictation now transits the
  pasteboard, so without this every utterance would land permanently in clipboard history.
  A convention, not enforcement.
- **Paste settle 400ms** (was 80ms PROVISIONAL) — ⌘V only *queues* the keystroke; the target
  app reads the pasteboard on its own schedule. 300–500ms is the sane band.
- **Thinking opt-out** — cleanup passes `chat_template_kwargs: {"enable_thinking": false}`
  (`SamplingParams.disableThinking`). Measured 27.35s → 1.79s on identical input.
- **Confirm-Back timeout** — 10s, and it copies to the clipboard rather than calling
  `reject()`, which silently destroyed the text.
- **Latency instrumentation** — per-stage timings on `DictationHistoryEntry`.

## Why P5 is split

P5 · Dictation is the hero feature — talk into any app, cleaned up — but it hides two independently demoable capabilities that do not need to land as one blob:

- **P5a · Dictation Core** (this doc) — hold ⌃Space → transcribe → (optional) single tone-aware cleanup pass → insert at the caret (~~AX-first, clipboard-paste fallback~~ **paste-only, see the amendment**, terminal-destination scan). Demoable as "Wispr Flow minus the personal dictionary."
- **P5b · Personalization Dictionary** — explicit "correct that" vocabulary, Whisper bias-prompt consumption, cleanup-prompt substitutions, Settings list. Demoable against P5a's cleanup/insert path once that path exists.

They share only the cleanup-prompt substitution slot and the Whisper `initialPrompt` slot. P5a builds the insertion + cleanup vertical with those slots empty (or with an injected no-op provider). P5b fills them. Each vertical is built and demoed to completion on its own. This doc is **P5a**.

**Explicitness override.** Other agents will implement these plans. The usual `write-a-prd` / `prd-to-plan` guidance to omit file paths is **waived**: this PRD and its plan name exact modules, protocol signatures, provisional constants, `Package.swift` / `project.yml` registration, and test cases. Do not "fix" that back to vagueness.

## Problem Statement

Aide can already hear the user (P2a) and route commands (P4), but **Dictation Mode still does not put words into the frontmost app**. Holding ⌃Space runs `STTVoiceSessionDriver`, which paints the transcript in the Overlay and stops. The caret never moves. There is no tone cleanup, no Accessibility insertion, no clipboard-paste fallback, no terminal-destination scan, and no Settings for any of it.

That gap is the whole product promise for dictation: speak, and the text lands where the user was already typing — in Notes, in VS Code, in a terminal — cleaned to the chosen tone, without a cold multi-second LLM load blocking the insert, and without pasting a destructive command into a shell unprompted.

Doing that well is not "call AXSetAttribute." It means: ~~a deep, testable insertion planner;~~ a thin AppKit shell that runs synthetic ⌘V on the main thread; clipboard save/restore so Aide never silently clobbers what the user copied; P3's already-shipped C11 rule firing *before any character is inserted* when the destination is a terminal; a single local cleanup pass that rewrites and never answers; a Settings toggle plus an automatic raw bypass when the sidecar is not ready (a modifier-key bypass was investigated and **rejected** — `Hotkeys.HotkeyBinder` matches chord flags exactly, so an extra modifier misses the dictation chord rather than signalling escape); and honest Overlay states when Accessibility is denied or both insert paths fail.

## Solution

A local **dictation vertical** that turns a held ⌃Space into text at the caret:

- **`DictationDriver`** replaces `STTVoiceSessionDriver` as the mux's dictation inner driver. Capture → Whisper → Pre-Gate stay as they are (lenient dictation mode). On Pre-Gate pass the driver inserts (raw in Phase 1; cleaned from Phase 3) and still delivers `.transcript` then a terminal `.result` / `.confirmBack` / `.hardBlocked` so **`VoiceSessionCoordinator` and the Overlay do not change**.
- **Text insertion** is **paste-only** (save all pasteboard types → set string with the nspasteboard skip markers → synthetic ⌘V → 400ms settle → restore), preceded by a Secure-Input preflight. All CGEvent work is `@MainActor` (LLD §10). *Originally specified AX-first with paste as fallback — reversed, see the amendment.*
- **Terminal destinations** are scanned with `ScanContext(channel: .dictatedOneOff, destinationBundleID:)` using the existing `DangerousCommandScanner`. `confirm` / `hardBlock` route to the existing Overlay Confirm-Back / Hard-Block **before any insert**. Approve inserts; reject drops. The terminal bundle-ID set is **not forked** — it is the scanner's `ScanRuleEngine.terminalBundleIDs` made public.
- **One cleanup pass** (LLD §4.6) on the local sidecar at temperature `0.2`, `stream: false`. Prompt from LLD §6.3. A fixed sanitizer strips preamble/wrapping quotes. Invariants: never add facts, never answer questions, never translate; preserve Hindi / code-mixed speech unless the preset formalizes register.
- **Tone presets** `as_is` (default), `professional`, `casual`, `concise`. Chosen by voice prefix `"professional tone: …"` > per-invocation setting > `settings.tone.default_preset`.
- **Raw bypass (locked):** `settings.dictation.cleanup_enabled` (default `true`). When `false`, insert the raw transcript and skip the LLM. When `true` but the sidecar is **not already `.ready`**, insert raw **immediately** (do **not** await `resolveLiveSidecarEndpoint`'s 45s cold start), show that in the Overlay, and optionally kick off a background sidecar warm for the *next* utterance.
- **Degradation:** Accessibility denied → fix-it + System Settings deep-link (`Permission.accessibility`; `canRequestInApp == false`) — still required, synthetic ⌘V needs it. Paste failed (or Secure Input active) → human-readable state + copy-to-clipboard escape. ~~Successful paste-fallback after AX failure records a per-app override in `settings.text_insertion.app_overrides`.~~ *(Override learning removed with AX — see the amendment.)*

P5b later injects dictionary substitutions into the cleanup prompt and a Whisper bias prompt into `initialPrompt`. P5a threads those as injected providers that default to empty / nil.

## User Stories

### Raw insertion (the vertical)
1. As a user, I want to hold ⌃Space, speak, and see my words appear at the caret in the frontmost app, so that dictation is real rather than Overlay-only.
2. As a user, I want insertion to run entirely on my Mac with no network call, so that dictated text never leaves the machine.
3. ~~As a user, I want Aide to try Accessibility insertion first, so that well-behaved AppKit/native fields get a caret insert without clobbering my clipboard.~~ **Dropped** — AX never actually inserted anywhere we could confirm (amendment). Clipboard clobbering is instead solved by save/restore plus the nspasteboard skip markers.
4. As a user in **any** app — Electron (VS Code, Slack), Catalyst (Messages, WhatsApp), or native — I want dictation to land through the one path that demonstrably works, so that insertion doesn't silently do nothing.
5. As a user, I want my previous clipboard restored after a paste fallback, so that Aide never silently eats what I had copied.
6. As a user, I want a failed insert to tell me why rather than swallowing the utterance.

### Terminal safety
7. As a user dictating into Terminal / iTerm2 / Warp / Ghostty / kitty / Alacritty / WezTerm, I want Aide to confirm before any character is inserted, so that a mishearing cannot run a shell command.
8. As a user, I want a Hard-Block (sudo, disk wipe, …) in dictated terminal text to be impossible to override, so that P3's rules still hold in dictation.
9. As a user, I want Approve on Confirm-Back to insert the (cleaned or raw) text, and Reject to drop it, so that the Overlay I already know is the whole UI.

### Tone cleanup
10. As a user, I want a single local cleanup pass that fixes grammar, punctuation, and filler while keeping my wording (`as_is` default), so that inserted text is readable without sounding like someone else.
11. As a user, I want Professional / Casual / Concise presets, so that I can match the document I'm typing into.
12. As a user, I want to say "professional tone: …" at the start of an utterance to override the preset for that utterance only.
13. As a user, I want cleanup to preserve Hindi and code-mixed speech and never translate, so that Aide does not "helpfully" rewrite me into English.
14. As a user, I want cleanup to never add facts or answer questions in the dictated text, so that a spoken question is inserted as a question.

### Raw bypass and latency
15. As a user, I want a Settings toggle to turn cleanup off, so that I can always insert raw when I want maximum speed.
16. As a user, I want raw text inserted immediately when the local LLM is not already ready, so that a cold ~4.7GB Qwen load never blocks dictation.
17. As a user, I want the Overlay to say when it inserted raw because the model wasn't ready, so that I'm not surprised by filler-words landing.

### Settings
18. As a user, I want a Dictation Settings pane to pick the default tone, toggle cleanup, and see per-app insertion overrides.
19. As a user, I want existing `settings.json` files to keep working after this schema bump, so that an upgrade does not reset my hotkeys.

### Degradation and learning
20. As a user who denied Accessibility, I want a fix-it hint that deep-links to Privacy → Accessibility (not a programmatic prompt), so that I can grant it myself.
21. As a user, I want "copy to clipboard" when the paste fails, so that I'm not stranded with text only in the Overlay.
22. ~~As a user, I want Aide to remember that VS Code needed paste, so that the next dictation in that app skips the doomed AX attempt.~~ **Dropped** — with one insertion path there is no per-app divergence to learn (amendment).
23. As a user, I want dictation turns written to local command history (`mode: dictation`), so that wipe/history tooling stays honest.

### Developer-facing
24. As a developer, I want `MuxVoiceSessionDriver`'s dictation argument swapped to `DictationDriver` with **no** change to the mux, `VoiceSessionCoordinator`, or Overlay state machine.
25. As a developer, I want insertion planning, tone parsing, prompt building, and response sanitizing as **pure headless modules** so AppKit stays a thin shell.
26. As a developer on P5b, I want injected `initialPrompt` and cleanup-substitution providers so the dictionary can land without rewriting the driver.

## Implementation Decisions

**Vertical boundary.** P5a owns hold-to-talk dictation → insert, including cleanup, Settings for tone/dictation/text_insertion, terminal scan wiring, and degradation. It does **not** own the Personalization Dictionary (P5b), Command Mode, Screen Q&A, or BYOK.

**Locked this session (do not reopen):**

| Decision | Lock |
|---|---|
| Split | P5a core + P5b dictionary, mirroring P2a/P2b |
| Cleanup default | On, with a raw bypass |
| Bypass mechanism | `dictation.cleanup_enabled` Settings toggle **plus** automatic bypass when the sidecar is not already `.ready`. **Not** a modifier-key escape: `HotkeyBinder.semanticHotkey(forKeyCode:modifiers:)` requires an exact `HotkeyChord` match (`Sources/Hotkeys/HotkeyBinder.swift`). Extra Shift/Option on ⌃Space fails the match instead of tagging a bypass. |
| Token counting | P5b concern (Whisper tokenizer behind `TokenCounting`). P5a does not tokenize. |
| Branch | `feat/p5a-dictation-core` off `main`; all P5a **and** P5b phases on this one branch (no per-phase branches or worktrees) |

**Modules.**

- **`Sources/Dictation/`** (new SwiftPM module, deep, headless, TDD). Depends on `AideCore`, `SpeechToText`, `LLMRuntime`, `DangerousCommandScanner`. Must **not** import AppKit, ApplicationServices, or `InferenceClient`.
  - `TextInserting` protocol + `InsertionFocus` / `InsertionResult` / `InsertionFailure` value types. **Deliberate LLD §3.5 deviation:** no `AXUIElement` on the protocol or in this module. *(As shipped: `insert(_:)` with no plan; `InsertionResult` is `.insertedViaPaste` / `.failed(InsertionFailure)` / `.copiedToClipboard`, where `InsertionFailure` is `.secureInput` or `.pasteFailed(detail:)`.)*
  - ~~`InsertionPlanner`~~ — **deleted with AX.** One path, nothing to plan.
  - ~~`TerminalBundleAllowlist`~~ — **deleted.** The driver reads the scanner's public `TerminalBundleIDs.allowlist` directly, which removes the two-sets-must-match risk rather than testing for it.
  - `TonePreset` — `as_is` / `professional` / `casual` / `concise` (raw values match settings JSON).
  - `TonePrefixParser` — strips a leading `"<preset> tone:"` (case-insensitive, optional space before colon).
  - `CleanupPromptBuilder` — LLD §6.3 template; substitutions default to empty in P5a.
  - `CleanupResponseSanitizer` — strip wrapping quotes and a small fixed preamble list ("Here is the cleaned text:", "Cleaned text:", "Sure,", etc.).
  - `DictationDriver` — `VoiceSessionDriver` conformer. On pass: parse tone prefix → maybe cleanup → maybe scan → insert. `approve()` / `reject()` / `confirmBackTimedOut()` override the default no-ops. *(As shipped, the capture → transcribe → Pre-Gate front half is **not** a copied `peakNormalize` helper: it was extracted to `SpeechToText.CaptureTranscribeGate` and shared with `STTVoiceSessionDriver`, superseding "Out of Scope: extracting duplicated `peakNormalize`". Cleanup is skipped entirely for terminal destinations, and the scan runs on the exact string about to be inserted.)*
- **`App/TextInserterLive.swift`** — `@MainActor` AppKit shell. Not in the headless suite (`HotkeyManager.swift` precedent). `just app` is the compile gate (`just check` / `swift build` **do not** compile `App/`).
- **`App/Settings/DictationPane.swift`** — registered by appending a `SettingsPane` to `App/Settings/SettingsRootView.swift`'s `panes` array (purely additive).

**Wiring.** `App/AppCoordinator+CommandMode.swift` `setUpCommandMode()` currently:

```
let dictation = STTVoiceSessionDriver(engine: capture: preGate:)
let mux = MuxVoiceSessionDriver(command: command, dictation: dictation)
```

Swap only the `dictation:` argument. Do not change `App/MuxVoiceSessionDriver.swift`, `Sources/VoiceSession/`, or Overlay types.

**Settings schema v6** (currently v5 — `Sources/Configuration/Settings.swift` `currentSchemaVersion = 5`). New blocks, all tolerant-decode with defaults:

- `tone`: `{ "default_preset": "as_is", "available": ["as_is", "professional", "casual", "concise"] }`
- `dictation`: `{ "cleanup_enabled": true }` — **not** in LLD §2.5's sample; added by the locked bypass. Document it in code comments.
- ~~`text_insertion`: `{ "app_overrides": { "<bundleID>": "ax" | "paste" } }` per LLD §2.5~~ — **not shipped.** The block went with AX (amendment); the schema still bumps to v6 for `tone` + `dictation`.

Append `SettingsMigration(from: 5, to: 6)` in `Sources/Configuration/SettingsMigration.swift`. Absent keys → defaults. Existing v5 files must round-trip.

**Sidecar bypass (MUST).** Do **not** call `AppCoordinator.resolveLiveSidecarEndpoint` (private, 45s wait) on the dictation path when the sidecar is cold. Probe current `SidecarState`; treat anything other than `.ready` as "not ready." Insert raw; Overlay summary MUST include that cleanup was skipped because the model wasn't ready (exact copy in the plan). Optionally `Task { try? await startIfNeeded }` fire-and-forget — never block the insert on it.

**Confirm-Back reuse.** `ConfirmBackInfo` requires `skillID: String` and `riskTier: RiskTier`. Dictation uses `skillID: "dictation_insert"`, `riskTier: .alwaysConfirm`, `intent:` the text that would be inserted, `transcript:` the same. Do not extend Overlay types.

**Cleanup LLM call:**

```
LLMClient.chat(
  system: CleanupPromptBuilder.system,  // or empty system + full user template — pick one and test it
  messages: [.init(role: .user, content: builtPrompt)],
  params: SamplingParams(temperature: 0.2, topP: 1.0, maxTokens: 1024, topLogprobs: 0),
  endpoint: <already-ready local endpoint>,
  stream: false
)
```

Concatenate `ChatCompletionChunk.delta` (non-streamed still yields one chunk). Dictation never uses a non-local endpoint (`endpoint.isLocal` guard).

**Injected P5b slots (P5a ships no-ops):**

```
var makeInitialPrompt: @Sendable () async -> String?   // default { nil }
var substitutionList: @Sendable () async -> String     // default { "" }  // the {{DICTIONARY_SUBSTITUTIONS}} body
```

**Permissions.** `Feature.textInsertion → .accessibility` already exists. `Permission.accessibility.canRequestInApp == false`. Live read stays `AXIsProcessTrusted()` in `App/SystemPermissionReader.swift`. Deep-link via existing `Permission` URL helper (`Privacy_Accessibility`).

**History.** Append a JSONL line through existing `Persistence.HistoryLog` on `storage.historyFile(for: Date())`. Include `mode: "dictation"`, transcript, whether cleanup ran, insertion result, destination bundle ID. Wipe already clears `history/` and already **spares** `dictionary.json` (`HistoryWipe` docs). Do not change wipe scope in P5a.

**No new third-party packages.** AppKit / ApplicationServices / Carbon for the live inserter only.

## Testing Decisions

**Approach: TDD (red-green-refactor), tests-first**, for every deep module. Pattern: `DangerousCommandScanner` + `STTVoiceSessionTests`. One behavior per cycle — do not write the whole suite then the whole impl.

**Good tests** drive public interfaces with mocks (`MockSTTEngine`, fake `AudioCaptureBuffer`, `MockLLMClient`, a recording `TextInserting` fake, a stub `CommandScanning`). No real AX, no real pasteboard, no real sidecar, no real mic.

**Modules under test:**

- ~~`InsertionPlanner`~~ — deleted with AX; `InsertionPlannerTests` removed.
- `TonePrefixParser` — each preset; missing prefix; prefix with extra spaces; prefix mid-sentence must **not** trigger.
- `CleanupPromptBuilder` — template contains tone instruction + raw transcript; empty substitutions omit a dangling list (or render an explicit "none").
- `CleanupResponseSanitizer` — wrapped quotes; "Here is the cleaned text: …"; already-clean text unchanged.
- `DictationDriver` — pass → insert raw (Phase 1) / cleaned (Phase 3); Pre-Gate fail → no insert; cancel → no insert; `cleanup_enabled == false` → no `chat` call; sidecar not ready → no `chat` call + overlay copy; terminal confirm → no insert until `approve()`; `reject()` drops; hardBlock never inserts.
- `Settings` v6 codec + `SettingsMigrator` v5→v6.
- ~~Terminal allowlist equality with the scanner set.~~ — moot; the driver uses the scanner's set directly.

**Not unit-tested (manual / `just app` compile):** `App/TextInserterLive.swift`, pasteboard save/restore, synthetic ⌘V, Settings pane layout.

**Per-phase gate (MUST):** `just check` green **and** `just app` builds **and** SwiftLint 0 warnings. `just check` does **not** compile `App/`. The pre-commit hook strict-verifies SwiftLint, **not** format — run `just check` after every commit so a format-only miss cannot land.

## Out of Scope

- **P5b · Personalization Dictionary** — `dictionary.json`, "correct that", Whisper bias budget, substitution injection. P5a leaves the two provider slots no-op.
- **Modifier-key raw bypass** — rejected.
- **Custom tones** — HLD §9.2, out of v1.
- **Streaming / partial insert** — batch-on-release, atomic insert.
- **Cloud cleanup / BYOK** — dictation never leaves the machine implicitly.
- **Wake word** dictation.
- **Changing `HotkeyBinder` matching** to support extra modifiers.
- ~~**Extracting duplicated `peakNormalize`** from `STTVoiceSessionDriver` / `CommandModeDriver`.~~ — **superseded.** A code review flagged the duplicated capture→transcribe→Pre-Gate front half; it was extracted to `SpeechToText.CaptureTranscribeGate` (placed in `SpeechToText`, which both dependents already import, so no pillar seam is crossed).
- Deferred P4-audit bugs (media-control AX preflight, timezone IDs, ParameterValidator `maximum`, unit aliases, sidecar `.failed` restart, etc.).

## Further Notes

- **Independence via seams:** `Dictation` depends on `AideCore` protocols + `SpeechToText` / `LLMRuntime` / `DangerousCommandScanner`. It does **not** depend on `CommandMode` or `BuiltinSkills`.
- **"Done" (acceptance demo):** hold ⌃Space in TextEdit → cleaned (or raw, if sidecar cold) text at caret; hold ⌃Space in Terminal → Overlay Confirm-Back, nothing inserted until Approve; Settings toggle cleanup off → raw insert even with sidecar warm; deny Accessibility → fix-it, not a crash. **Verified** against Messages, Ghostty and Dia.
- **Reference machine:** Apple M2 / 16GB, macOS 14+, Apple Silicon only.
- This PRD is the input to [`plans/P5a-dictation-core.md`](../plans/P5a-dictation-core.md). P5b gets its own PRD.
