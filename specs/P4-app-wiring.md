# PRD — P4 · App Wiring (Command Mode Integration)

> Addendum to [`specs/P4-command-routing-and-skills.md`](./P4-command-routing-and-skills.md).
> Completes the P4 pillar by wiring the headless SwiftPM modules into the menubar app.
> Status: spec · not yet planned.

## Problem Statement

P4 Phases 1–7 shipped the full headless decision core: manifest model, skill
registry, router, confidence gate, dispatcher, built-in skills, calibration
logger, and the `CommandModeDriver` conforming to `VoiceSessionDriver`. All 927+
tests pass headlessly.

But the app can't run Command Mode. Five concrete gaps stand between "tests pass"
and "hold the hotkey, say *open Safari*, Safari opens":

1. **No P4 modules in the app target** — `project.yml` lists zero P4 products.
   The app binary doesn't link `SkillManifest`, `SkillRegistry`, `CommandRouter`,
   `CommandDispatcher`, `BuiltinSkills`, or `CommandMode`.

2. **No mode mux** — `AppCoordinator` constructs a single `STTVoiceSessionDriver`
   for both hotkeys. Both `.command` and `.dictation` run through the same
   transcription-only pipeline. There is no `CommandModeDriver` instance and no
   mechanism to route the command hotkey to it.

3. **No production `SystemSkillExecutor`** — effectful skills (open/quit app,
   timer, media, screenshot) route through the `SystemSkillExecutor` protocol,
   but only a test mock exists. The real AppKit implementation hasn't been written.

4. **No manifest catalog** — `InMemorySkillRegistry` needs a `[Manifest]` array,
   but no built-in manifest catalog exists in `Sources/`. Tests use scattered
   one-off fixtures. The composition root can't construct the registry.

5. **Overlay outcomes are collapsed** — `CommandModeDriver` collapses every
   `DispatchOutcome` (executed, confirmBack, promptedBack, hardBlocked, failed)
   into a flat `.result(summary: String)`. The Overlay has `.confirmBack` /
   `.promptBack` states and `.presentConfirmBack` / `.presentPromptBack` /
   `.approve` / `.reject` events fully modeled and unit-tested in the state
   machine — but nothing in the live pipeline ever emits them. The user sees
   text but can never approve or reject a confirm-back.

Additionally, two PRD-scoped items were omitted from the 7-phase plan:

6. **Unit conversion skill** — PRD v1 in-scope; Phase 6 ACs omitted it.
7. **Filesystem skill registry** — PRD says the registry "loads/watches manifest
   files from `registry/`", but only `InMemorySkillRegistry` was built.

## Solution

Wire the headless P4 modules into the app through five integration pieces:

- **`BuiltinManifestCatalog`** — a static `[Manifest]` constant in the
  `BuiltinSkills` module containing all built-in skills with correct parameter
  schemas, risk tiers, and utterance examples.

- **`SystemSkillExecutorLive`** — a production `SystemSkillExecutor` conformer
  in `App/` that uses `NSWorkspace`, `UNUserNotificationCenter`, `CGEvent` media
  keys, and `/usr/sbin/screencapture` to perform real OS effects.

- **`MuxVoiceSessionDriver`** — a thin `VoiceSessionDriver` conformer in `App/`
  that routes `.command` → `CommandModeDriver` and `.dictation` →
  `STTVoiceSessionDriver`. `VoiceSessionCoordinator` stays unchanged; it sees
  one driver.

- **Structured overlay integration** — extend `VoiceSessionUpdate` with
  `.confirmBack`, `.promptBack`, `.hardBlocked` cases so `CommandModeDriver`
  can deliver structured outcomes instead of collapsed strings. Extend
  `VoiceSessionDriver` with `approve()` / `reject()` (default no-ops via
  extension). Update `VoiceSessionCoordinator` to map the new cases onto
  `OverlayEvent.presentConfirmBack` / `.presentPromptBack`, and to route user
  approve/reject decisions back through the driver. Make the Overlay's
  `.confirmBack` state interactive (approve/reject buttons).

- **Filesystem skill registry** — a `FileSkillRegistry` actor that loads
  manifests from `registry/` on disk and merges them with the built-in catalog.

- **Unit conversion skill** — a pure skill using Foundation's `Measurement` APIs.

## User Stories

### Manifest Catalog

1. As a developer wiring the app, I want a single `BuiltinManifestCatalog.all`
   constant that returns validated manifests for all built-in skills, so the
   composition root can construct the registry without duplicating manifest
   definitions across test fixtures.

2. As a developer, I want the manifest catalog's risk tiers to match the spec
   (LLD §4.2): `current_time`, `calculate`, `general_qa`, `screen_qa` are
   `.low`; `open_application`, `quit_application`, `media_control`, `set_timer`
   are `.confirm`; `take_screenshot` is `.alwaysConfirm`.

3. As a developer, I want the manifest catalog's parameter schemas to match
   what `BuiltinSkillRouter` actually extracts, so router-emitted parameters
   always pass schema validation.

### Production System Executor

4. As a user saying "open Safari", I want Safari to actually launch (not just
   see "Opened Safari" text from a mock).

5. As a user saying "quit Finder", I want the running Finder process to
   terminate.

6. As a user saying "set a timer for 5 minutes", I want a macOS notification
   to fire after 5 minutes.

7. As a user saying "play" or "next track", I want media playback to respond.

8. As a user saying "take a screenshot", I want a real screenshot saved to disk
   and its path available for display.

### Mode Mux

9. As a user pressing the command hotkey, I want my voice routed through the
   command pipeline (STT → Route → Gate → Dispatch), not the dictation pipeline.

10. As a user pressing the dictation hotkey, I want the existing dictation
    behavior unchanged — transcription, no routing.

11. As a developer, I want both hotkeys to work through the same
    `VoiceSessionCoordinator` without changing its code, so the voice-session
    loop doesn't need a command-mode branch.

### App Composition Root

12. As a developer, I want the full command-mode dependency chain constructed in
    `AppCoordinator` — registry, router, dispatcher, driver — with production
    dependencies injected (real `WhisperSTTEngine`, real `InferenceClient`, real
    `DangerousCommandScanner`, real `SystemSkillExecutorLive`).

13. As a developer, I want the Router and `CommandModeDriver` to use only a
    local `LLMEndpoint` (the sidecar), so command routing never leaves the
    machine.

14. As a developer, I want `project.yml` to list all 6 P4 SwiftPM products, and
    `just gen` to regenerate the Xcode project successfully.

### Overlay Confirm-Back / Prompt-Back

15. As a user, I want a confirm-tier command (e.g. "open Safari" at marginal
    confidence, or "take a screenshot") to show the Overlay's confirm-back state
    with an Approve and Reject button — not just a flat text summary.

16. As a user, I want to tap Approve on a confirm-back and see the skill
    actually execute, with the result shown in the Overlay.

17. As a user, I want to tap Reject on a confirm-back and see the Overlay
    dismiss — the command is not run.

18. As a user, I want a prompt-back ("Did you mean…?") to appear when the
    router can't resolve my command, and auto-dismiss after a timeout.

19. As a user, I want a hard-blocked command to show a result-style warning
    with no approve option — it's blocked, period.

20. As a user, I want hard-blocked outcomes to remain visible in the Overlay
    with the same auto-hide timing as normal results (no silent discard).

### Calibration Reconciliation

21. As a developer, I want `CalibrationRecord.userOutcome` to be populated when
    the user approves ("accepted"), rejects ("rejected"), or a prompt-back
    auto-dismisses ("dismissed") — not `null` forever.

22. As a developer, I want calibration records for `.executed` outcomes (where
    no user interaction occurs) to keep `userOutcome: null` — there is no
    decision to record.

### Unit Conversion

23. As a user saying "convert 10 miles to kilometers", I want the result
    "16.09 km" shown in the Overlay.

24. As a user saying "how many pounds is 5 kilograms", I want an accurate
    conversion result.

25. As a developer, I want the `unit_conversion` skill to use Foundation's
    `Measurement` APIs so conversions are precise and cover length, mass,
    temperature, volume, speed, and area.

### Filesystem Skill Registry

26. As a developer, I want a `FileSkillRegistry` that loads `*.json` manifest
    files from the `registry/` directory under `StorageLayout`, validates them,
    and merges them with the built-in manifest catalog.

27. As a developer, I want the filesystem registry to watch for changes
    (add/remove/modify manifest files) and update the grammar and prompt catalog
    automatically, so P7 user-automations can drop manifests on disk and have
    them appear in the router.

28. As a developer, I want invalid manifests on disk to be silently skipped
    (logged but not crash-inducing), consistent with `InMemorySkillRegistry`'s
    behavior.

### History Wipe Verification

29. As a user choosing "Wipe all history" with the calibration option, I want
    `logs/calibration.jsonl` to be deleted.

30. As a user choosing "Wipe all history" without the calibration option, I want
    `logs/calibration.jsonl` spared — it's opt-in, not automatic.

## Implementation Decisions

### ID-1: MuxVoiceSessionDriver as a composition wrapper

A thin `VoiceSessionDriver` conformer (`MuxVoiceSessionDriver`) in `App/` holds
two inner drivers — `CommandModeDriver` for `.command`, `STTVoiceSessionDriver`
for `.dictation`. `begin(mode:)` picks the active driver; `end()` / `cancel()`
forward to it. The `onUpdate` callback is set on both inner drivers (only the
active one fires — each driver has its own generation guard).

`VoiceSessionCoordinator` is completely unchanged. It sees one driver.

### ID-2: Extend VoiceSessionUpdate with structured outcomes

New cases added to `VoiceSessionUpdate` in `AideCore`:

- `.confirmBack(ConfirmBackInfo)` — carries transcript, intent description,
  skill ID, risk tier (a new lightweight AideCore struct, not
  `CommandDispatcher.ConfirmBackPrompt` — AideCore can't depend on
  CommandDispatcher).
- `.promptBack(transcript: String, suggestion: String?)` — low-confidence or
  null skill.
- `.hardBlocked(transcript: String, reason: String)` — scanner hard-block.

`CommandModeDriver` emits these instead of collapsing all outcomes to
`.result(summary:)`. The `.failed` case maps to `.result` (transient errors
are shown as plain results).

### ID-3: VoiceSessionDriver gains approve() / reject() with default no-ops

```swift
extension VoiceSessionDriver {
    public func approve() {}
    public func reject() {}
}
```

`STTVoiceSessionDriver` and `MockVoiceSessionDriver` inherit the no-ops — zero
changes. `CommandModeDriver` overrides: `approve()` re-dispatches a stashed
`RoutedIntent` (bypassing the gate); `reject()` clears the stash and delivers
a dismiss.

`VoiceSessionCoordinator` gains `approveConfirmBack()` and
`rejectConfirmBack()` methods. The App layer wires the Overlay's button actions
to these.

### ID-4: Overlay interactivity for confirm-back

`OverlayPanel` lifts `ignoresMouseEvents` when the state is `.confirmBack` (so
buttons work). `OverlayView` renders Approve / Reject buttons in the
`.confirmBack` state. `OverlayController` gets `onApprove` / `onReject`
closures that `AppCoordinator` wires to the coordinator.

### ID-5: BuiltinManifestCatalog lives in BuiltinSkills

The catalog co-locates with the skill implementations in the `BuiltinSkills`
module. Each manifest's parameter schema is the source of truth for what the
corresponding skill's `run(parameters:)` method expects.

### ID-6: FileSkillRegistry merges disk + built-in manifests

`FileSkillRegistry` (new actor in `SkillRegistry` module) wraps
`InMemorySkillRegistry` internally. It takes a `registryDirectory: URL` (from
`StorageLayout`) and the `BuiltinManifestCatalog.all` array. On init and on
file changes, it re-scans the directory, validates each manifest, merges with
built-ins (built-ins win on ID conflict), and rebuilds the inner registry.

Disk manifests have `kind: .userAutomation`; they must include `scriptRef` and
`scriptSha256` per validation rules. Built-in manifests have `kind: .builtin`.

### ID-7: Composition root bootstrapping is async

`LocalCommandRouter` takes pre-rendered `skillCatalog` and `grammar` strings,
which require `await`ing the registry actor. The composition root in
`AppCoordinator.setUp()` does this async initialization once at launch. The
grammar and catalog are not rebuilt on registry changes in this phase (the
filesystem watcher triggers a rebuild in the `FileSkillRegistry` actor, which
internally rebuilds).

## Testing Decisions

### What makes a good test here

Tests assert external behavior through module boundaries. They use the
existing seam protocols and mocks — never reach into private state. Prior art:
`Tests/CommandModeTests/CommandModeDriverTests.swift` (mock engine + mock router
+ mock dispatcher → assert updates), `Tests/VoiceSessionTests/VoiceSessionCoordinatorTests.swift`
(fake driver + overlay-send spy → assert event sequences).

### Modules tested

- **BuiltinManifestCatalog** — all manifests pass validation, correct risk tiers,
  correct count, parameter schemas match router expectations. Headless.

- **UnitConversionSkill** — pure function: `(value, fromUnit, toUnit)` → expected
  result for length, mass, temperature, volume. Edge cases: same-unit no-op,
  unknown unit → error. Headless.

- **VoiceSessionCoordinator** (extended) — new test cases for `.confirmBack` /
  `.promptBack` / `.hardBlocked` updates → correct overlay events emitted. Test
  `approveConfirmBack()` → driver.approve() called → subsequent `.result` →
  `.presentResult`. Test `rejectConfirmBack()` → `.reject` emitted. Headless.

- **CommandModeDriver** (updated) — existing tests updated: confirm-back outcome
  → `.confirmBack(ConfirmBackInfo)` not `.result(string)`. New tests for
  `approve()` re-dispatch and `reject()` dismiss. Headless.

- **FileSkillRegistry** — loads fixtures from temp directory, validates, merges
  with built-ins. Invalid manifest → skipped. File add/remove → registry
  updated. Headless.

- **HistoryWipe** — verify existing tests cover `includeCalibrationLog: true`
  and `false`. If already covered, no new tests needed.

### Not tested headlessly

- `SystemSkillExecutorLive` — AppKit-dependent; tested manually via `just app`.
- `MuxVoiceSessionDriver` — thin delegation; tested transitively through
  coordinator tests with the existing `FakeDriver` pattern, and manually.
- `AppCoordinator` composition root — integration; tested via `just app` + manual.

## Out of Scope

- **Dictation Mode** — P5. The mux routes `.dictation` to the existing
  `STTVoiceSessionDriver` unchanged.
- **Real Q&A / Screen Q&A** — P6. `general_qa` and `screen_qa` remain stubs.
- **Cloud Escalation** — P6. Router always uses local endpoint.
- **User Script-Automations** — P7. `FileSkillRegistry` enables P7 to drop
  manifests on disk, but the script generation/execution is P7.
- **Weather / Calendar / Currency skills** — deferred (need network / TCC).
- **Confirm-Back modal (separate window)** — P1's `ConfirmationModal` concern.
  P4 uses inline buttons in the Overlay panel.
- **Session Context** — P6. Router prompt carries transcript only.

## Further Notes

- The existing P4 headless modules are locked (Phases 1–7). This work extends
  them without reopening validated decisions (dispatch order, GBNF format,
  calibration schema, action_taken enum).
- `VoiceSessionDriver` protocol changes (approve/reject) are the one seam
  modification. Default no-op extensions ensure zero breakage for existing
  conformers.
- The `ConfirmBackInfo` type in AideCore is deliberately minimal (no
  `DangerousCommandScanner.Finding` — AideCore can't depend on that module).
  The Overlay shows "Confirm this action?" with the intent description; detailed
  findings are logged to calibration, not shown to the user in v1.
