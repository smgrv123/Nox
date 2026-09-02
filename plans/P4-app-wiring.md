# Plan: P4 App Wiring (Command Mode Integration)

> Source PRD: `specs/P4-app-wiring.md`
> Continues from: `plans/P4-command-routing-and-skills.md` (Phases 1–7, all complete)

## Architectural decisions

Durable decisions that apply across all phases:

- **Mode mux**: `MuxVoiceSessionDriver` in `App/` — thin `VoiceSessionDriver`
  conformer that delegates `.command` → `CommandModeDriver`, `.dictation` →
  `STTVoiceSessionDriver`. `VoiceSessionCoordinator` is unchanged.
- **Seam extension**: `VoiceSessionUpdate` gains `.confirmBack(ConfirmBackInfo)`,
  `.promptBack(String, String?)`, `.hardBlocked(String, String)`.
  `VoiceSessionDriver` gains `approve()` / `reject()` with default no-op
  extensions.
- **ConfirmBackInfo**: lightweight struct in `AideCore` carrying `transcript`,
  `intent`, `skillID`, `riskTier`. Not `CommandDispatcher.ConfirmBackPrompt` —
  AideCore can't depend on CommandDispatcher.
- **Manifest catalog**: `BuiltinManifestCatalog` (static `[Manifest]`) lives in
  the `BuiltinSkills` module, co-located with the skill implementations.
- **Composition root**: async bootstrap in `AppCoordinator.setUp()`. Registry
  pre-renders grammar and catalog strings for the router at launch.
- **Filesystem registry**: `FileSkillRegistry` actor in `SkillRegistry` module,
  wraps `InMemorySkillRegistry`, merges disk manifests with built-ins.
- **Gating**: `just check` (format + lint + build + test) after every phase.
  `just app` after Phase 2+. Each phase is reviewed before the next begins.

---

## Phase 1: Built-in Manifest Catalog

**User stories**: 1, 2, 3

### What to build

A static manifest catalog for all 9 built-in skills, living in the `BuiltinSkills`
module. Each manifest carries the correct `id`, `description`, `utteranceExamples`,
`parameters` (JSON Schema matching what `BuiltinSkillRouter` actually extracts),
`riskTier`, `permissions`, and `kind: .builtin`.

The 9 skills and their risk tiers (LLD §4.2):

| Skill ID | Risk Tier |
|----------|-----------|
| `current_time` | `.low` |
| `calculate` | `.low` |
| `general_qa` | `.low` |
| `screen_qa` | `.low` |
| `open_application` | `.confirm` |
| `quit_application` | `.confirm` |
| `set_timer` | `.confirm` |
| `media_control` | `.confirm` |
| `take_screenshot` | `.alwaysConfirm` |

TDD: write the test first asserting all 9 manifests pass `ManifestValidation`,
have the correct risk tiers, and the count is exactly 9. Then implement the catalog.

### Acceptance criteria

- [x] `BuiltinManifestCatalog.all` returns exactly 9 manifests
- [x] Every manifest passes `ManifestValidation.validate()` with zero errors
- [x] Every manifest ID is routable by `BuiltinSkillRouter` (IDs match the router's switch cases)
- [x] Risk tiers match the table above
- [x] Parameter schemas match what each skill's `run(parameters:)` method extracts
- [x] `just check` green

---

## Phase 2: App Wiring Tracer Bullet (Pure Skills)

**User stories**: 9, 10, 11, 12, 13, 14

### What to build

The minimum wiring to get one end-to-end command-mode path working: hold the
command hotkey, say "what time is it", see the current time in the Overlay.

Three pieces:

1. **project.yml** — add the 6 P4 SwiftPM products (`SkillManifest`,
   `SkillRegistry`, `CommandRouter`, `CommandDispatcher`, `BuiltinSkills`,
   `CommandMode`) under `Aide.dependencies`. Run `just gen`.

2. **MuxVoiceSessionDriver** — a `VoiceSessionDriver` conformer in `App/` that
   holds a command driver and a dictation driver. `begin(mode:)` picks the
   active one; `end()` / `cancel()` forward to it. `onUpdate` didSet forwards
   to both inner drivers (only the active one fires — each has its own
   generation guard).

3. **AppCoordinator composition root** — construct the full command-mode
   dependency chain:
   - `InMemorySkillRegistry(manifests: BuiltinManifestCatalog.all)`
   - `LocalCommandRouter(client: inferenceClient, skillCatalog: ..., grammar: ...)`
     with catalog/grammar strings pre-rendered from the registry at launch
   - `CommandDispatcher(registry:, scanner: DangerousCommandScanner(), executor: BuiltinSkillRouter(system: stubExecutor), thresholds: .provisional)`
   - `CommandModeDriver(engine:, capture:, preGate:, router:, dispatcher:, registry:, logger:, endpoint:)`
   - `MuxVoiceSessionDriver(command: commandDriver, dictation: voiceDriver)`
   - Inject mux into `VoiceSessionCoordinator`

   Use a **no-op stub** `SystemSkillExecutor` for this phase (effectful skills
   return a placeholder result like "open_application: not yet wired"). Pure
   skills (`current_time`, `calculate`) work for real since they don't go
   through the executor.

   The router and driver must use a local `LLMEndpoint` — the sidecar's endpoint.

### Acceptance criteria

- [x] All 6 P4 products listed in `project.yml`; `just gen` succeeds
- [x] `MuxVoiceSessionDriver` routes `.command` to `CommandModeDriver`
- [x] `MuxVoiceSessionDriver` routes `.dictation` to `STTVoiceSessionDriver`
- [x] `VoiceSessionCoordinator` init and code are unchanged
- [x] Command hotkey → "what time is it" → current time shown in Overlay
- [x] Command hotkey → "calculate 5 plus 3" → "8" shown in Overlay
- [x] Dictation hotkey → unchanged behavior (no regression)
- [x] `just check` green
- [x] `just app` builds the .app successfully

---

## Phase 3: Production SystemSkillExecutor

**User stories**: 4, 5, 6, 7, 8

### What to build

Replace the Phase 2 stub executor with a real `SystemSkillExecutorLive` in `App/`
that performs actual macOS operations:

- `openApplication(appName:)` → `NSWorkspace` to launch or focus the named app
- `quitApplication(appName:)` → find `NSRunningApplication` by name → `.terminate()`
- `setTimer(durationSeconds:label:)` → `UNUserNotificationCenter` scheduled notification
- `mediaControl(action:)` → simulate media key events via `CGEvent`
- `takeScreenshot(region:)` → shell out to `/usr/sbin/screencapture`

Swap `SystemSkillExecutorLive()` into the composition root in place of the stub.

### Acceptance criteria

- [x] `SystemSkillExecutorLive` conforms to `SystemSkillExecutor` — no stubs or `fatalError`
- [x] "open Safari" → Safari launches or focuses
- [x] "quit TextEdit" → TextEdit terminates (if running)
- [x] "set a timer for 10 seconds" → notification fires after 10 seconds
- [x] "play" / "pause" / "next track" → media key event sent
- [x] "take a screenshot" → screenshot file saved, path in result summary
- [x] `just check` green
- [x] `just app` builds

---

## Phase 4: Overlay Confirm-Back / Prompt-Back + Calibration Reconciliation

**User stories**: 15, 16, 17, 18, 19, 20, 21, 22

### What to build

Wire the full confirm-back / prompt-back flow end-to-end so the Overlay shows
interactive confirmation for risky commands instead of flat text summaries.

Five sub-steps, each building on the last:

**4a — ConfirmBackInfo + VoiceSessionUpdate extension (AideCore)**

Add a `ConfirmBackInfo` struct to AideCore (transcript, intent, skillID,
riskTier). Add three new cases to `VoiceSessionUpdate`: `.confirmBack(ConfirmBackInfo)`,
`.promptBack(String, String?)`, `.hardBlocked(String, String)`.

**4b — VoiceSessionDriver approve/reject (AideCore)**

Add `approve()` and `reject()` to the `VoiceSessionDriver` protocol with
default no-op implementations via extension. Existing conformers
(`STTVoiceSessionDriver`, `MockVoiceSessionDriver`) inherit the no-ops
unchanged.

**4c — CommandModeDriver structured outcomes (CommandMode)**

Replace the `summary(for:)` string collapse: `.executed` → `.result`,
`.confirmBack` → `.confirmBack(ConfirmBackInfo)`, `.promptedBack` →
`.promptBack(...)`, `.hardBlocked` → `.hardBlocked(...)`, `.failed` → `.result`.
Stash the `RoutedIntent` on confirm-back for re-dispatch. `approve()` re-dispatches
the stashed intent (bypassing the gate). `reject()` clears the stash.

**4d — VoiceSessionCoordinator overlay mapping (VoiceSession)**

Extend `apply(_:)` to handle the new update cases: `.confirmBack` →
`emit(.presentConfirmBack)` (no auto-hide — waits for user); `.promptBack` →
`emit(.presentPromptBack)` + auto-hide; `.hardBlocked` → `emit(.presentResult)` +
auto-hide (hard-blocks show as results with no approve option).
Add `approveConfirmBack()` → `driver.approve()` and `rejectConfirmBack()` →
`emit(.reject)` + `driver.reject()`.

**4e — Interactive Overlay (App)**

Lift `ignoresMouseEvents` on the overlay panel when state is `.confirmBack`.
Add Approve / Reject buttons to `OverlayView`'s `.confirmBack` state. Wire
button actions through `OverlayController` callbacks → `AppCoordinator` →
`voiceSession.approveConfirmBack()` / `.rejectConfirmBack()`.

**4f — Calibration user_outcome**

After approve → re-dispatch resolves, log `"accepted"`. After reject, log
`"rejected"`. After prompt-back auto-dismiss, log `"dismissed"`. `.executed`
outcomes keep `userOutcome: null`.

### Acceptance criteria

- [x] `VoiceSessionUpdate` has `.confirmBack`, `.promptBack`, `.hardBlocked` cases
- [x] `VoiceSessionDriver` has `approve()` / `reject()` with default no-ops
- [x] `CommandModeDriver` emits structured outcomes (not collapsed strings)
- [x] Coordinator emits `.presentConfirmBack` / `.presentPromptBack` to Overlay
- [x] "take a screenshot" → confirm-back shown with Approve + Reject buttons
- [x] Approve → skill executes → result shown in Overlay
- [x] Reject → Overlay dismisses → command not run
- [x] Hard-blocked command → result-style warning, no approve option, auto-hides
- [x] Prompt-back → "Did you mean…?" shown → auto-hides after timeout
- [x] Calibration `user_outcome` populated: `accepted` / `rejected` / `dismissed`
- [x] `.executed` outcomes keep `userOutcome: null`
- [x] Existing `VoiceSessionCoordinatorTests` pass (no regression)
- [x] Existing `CommandModeDriverTests` updated for new update types
- [x] `just check` green

---

## Phase 5: Unit Conversion Skill

**User stories**: 23, 24, 25

### What to build

A pure built-in skill using Foundation's `Measurement` and `Unit` APIs.
Covers length, mass, temperature, volume, speed, and area conversions.

- Add the skill implementation to `BuiltinSkills` (pure function, no system executor).
- Add its case to `BuiltinSkillRouter.pureResult`.
- Add its manifest to `BuiltinManifestCatalog.all` (risk tier: `.low`).
- Parameters: `{ value: number, from_unit: string, to_unit: string }`.
- TDD: test expected conversions, same-unit no-op, unknown unit → error.

### Acceptance criteria

- [x] "convert 10 miles to kilometers" → "16.09 km"
- [x] "how many pounds is 5 kilograms" → "11.02 lb"
- [x] Temperature conversions work (Celsius ↔ Fahrenheit ↔ Kelvin)
- [x] Unknown unit string → graceful error (not crash)
- [x] Same-unit conversion returns the input value
- [x] Manifest passes validation, risk tier `.low`
- [x] `BuiltinManifestCatalog.all` count is now 10
- [x] `BuiltinSkillRouter` routes `unit_conversion` to the new skill
- [x] `just check` green

---

## Phase 6: Filesystem Skill Registry + History Wipe Verification

**User stories**: 26, 27, 28, 29, 30

### What to build

**Filesystem registry:** a `FileSkillRegistry` actor in the `SkillRegistry`
module that loads `*.json` manifest files from the `registry/` directory
(sourced from `StorageLayout`), validates them, and merges them with the
built-in catalog. Built-in manifests win on ID conflict. Invalid disk manifests
are silently skipped (logged, not crash-inducing).

On file changes (add/remove/modify), the registry re-scans, re-validates, and
rebuilds the inner `InMemorySkillRegistry`. The grammar and prompt catalog
regenerate automatically.

Disk manifests must have `kind: .userAutomation` and include `scriptRef` /
`scriptSha256` per `ManifestValidation` rules.

Swap `FileSkillRegistry` into the `AppCoordinator` composition root in place of
bare `InMemorySkillRegistry`.

**History wipe verification:** confirm that existing `HistoryWipeTests` cover
`includeCalibrationLog: true` (deletes `logs/calibration.jsonl`) and `false`
(spares it). If tests already cover this, mark done. If not, add the missing
assertions.

### Acceptance criteria

- [ ] `FileSkillRegistry` loads valid manifests from a directory
- [ ] Invalid manifests are skipped (no crash)
- [ ] Built-in manifests win on ID conflict with disk manifests
- [ ] File add → skill appears in registry's grammar and catalog
- [ ] File remove → skill removed from grammar and catalog
- [ ] `AppCoordinator` uses `FileSkillRegistry` instead of `InMemorySkillRegistry`
- [ ] `HistoryWipe` with `includeCalibrationLog: true` deletes `logs/calibration.jsonl`
- [ ] `HistoryWipe` with `includeCalibrationLog: false` spares it
- [ ] `just check` green

---

## Dependency order

```
Phase 1 (manifest catalog)
    │
    ▼
Phase 2 (app wiring tracer bullet — pure skills)
    │
    ▼
Phase 3 (production SystemSkillExecutor)
    │
    ▼
Phase 4 (overlay confirm-back + calibration)
    │
    ▼
Phase 5 (unit conversion)     ← independent, can run alongside Phase 4 or after
    │
    ▼
Phase 6 (filesystem registry + history wipe)
```

Phases execute sequentially with user review between each. Phases 5 and 6 are
independent of each other and could theoretically run in parallel, but are
sequenced for review simplicity.
