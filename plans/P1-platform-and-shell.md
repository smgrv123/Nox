# Plan: P1 · Platform & Shell

> Source PRD: [`specs/P1-platform-and-shell.md`](../specs/P1-platform-and-shell.md)
> Pillar context: [`docs/07-implementation-pillars.md`](../docs/07-implementation-pillars.md) · HLD §13–16 · LLD §2.5–2.7, §8–10

## Architectural decisions

Durable decisions that apply across all phases:

- **Stack:** Swift / SwiftUI, Apple Silicon, macOS 14+. Project via **XcodeGen** (`project.yml` is source of truth; `Aide.xcodeproj` generated + gitignored) with local **SwiftPM** modules under `Sources/`. Menubar-only app (`LSUIElement = YES`, no Dock icon).
- **Module layering:** pure-logic modules live in the SwiftPM package (`AideCore` + feature modules) and are tested headlessly via `swift test`; the app target (`App/`) is a thin SwiftUI/AppKit shell that depends on them.
- **Seam pattern (independence):** P1 depends only on `AideCore` protocols. A **voice-session driver** protocol + a **mock** conformer drive the interaction loop. Real STT/routing (P2/P4) satisfy the same protocol later with **no P1 change**. `AideCore` is the shared contracts/types layer beneath all pillars — not a pillar itself.
- **Overlay:** a **non-activating `NSPanel`** (never becomes key/main → never steals focus) hosting SwiftUI. A **separate ordinary modal** window is used for focus-taking (typed/destructive) confirmation. The Menubar is a separate `MenuBarExtra` surface.
- **Hotkeys:** global **`CGEventTap`**; defaults ⌥Space (command mode) / ⌃Space (dictation mode), both push-to-talk. Push-to-talk is the flow-control mechanism (one utterance in flight; a new press while processing cancels the prior).
- **Storage:** everything under `~/Library/Application Support/Aide/`. Single schema-versioned `settings.json`. Secrets never in the file — Keychain only, referenced by `keychain://` URI. Logs are plain-text (`app.log`) + append-only JSONL (history). **Wipe scope** = transcripts + command-history + script-logs only (never settings/scripts/dictionary unless explicitly chosen).
- **Permissions:** each detected **independently and prompt-free**; a denied permission disables only its dependent features with a persistent fix-it hint + System Settings **deep-link**. App Sandbox **off** (v1); Hardened Runtime **on**; entitlements configured day one (signing/notarization a later flip).
- **Concurrency (MUST):** all `AXUIElement` / `CGEvent.post` calls and all overlay/menubar UI on the **main actor**; the `CGEventTap` callback returns immediately (no heavy work in the tap); **single-instance** enforced at launch.
- **No network in P1.** Model downloads (P2) and utility calls (P6) are out of scope; the foundation is trivially offline-correct.
- **Testing:** **TDD (tests-first, red-green-refactor)** for the deep modules (`OverlayState`, `HotkeyManager` binding, `PermissionGate`, `Configuration`/`Persistence`, `Onboarding` flow). Tests exercise external behavior through public interfaces, with time/permission-status/grant-events **injected** for determinism. Prior art: the existing `DangerousCommandScanner` module + XCTest suite. SwiftUI/`NSPanel`/`MenuBarExtra` shells and the live `CGEventTap` install are verified by running the app, not unit-tested.

### Cross-phase gating (applies to every phase)

Per the phase rules, a phase is **not done** until:

- [ ] `swift build` and `swift test` pass (no errors/warnings introduced).
- [ ] `xcodegen generate` succeeds and the app target compiles (`xcodebuild … CODE_SIGNING_ALLOWED=NO build`).
- [ ] The phase's demo/verification is performed.
- [ ] Code follows the repo's conventions (see `CLAUDE.md` / any coding standards).
- [ ] **User reviews and approves the phase before the next phase begins.** Phases are executed one at a time, never all at once.

---

## Phase 1: Menubar app skeleton

**User stories**: 1, 3, 4, 36

### What to build
A menubar-only app that launches with no Dock icon and presents a `MenuBarExtra` menu showing a status line, an entry that opens a (currently empty) Settings window, and Quit. Enforce a single running instance at launch. Establish the `AppCoordinator` that owns app lifecycle. Formalize the existing tracer-bullet menubar into this structure.

### Acceptance criteria
- [ ] App launches as a menubar item with **no Dock icon**; menu shows status + Settings + Quit.
- [ ] Launching a second copy does not start a second instance (single-instance enforced).
- [ ] Selecting Settings opens an empty Settings window; Quit terminates cleanly.
- [ ] Cross-phase gating checks pass.

---

## Phase 2: Storage tree + logging

**User stories**: 33, 35

### What to build
On first launch, create the Application Support directory tree under `~/Library/Application Support/Aide/` (settings, dictionary, registry, scripts, history, logs, models slots). Provide a plain-text `app.log` logger and an append-only JSONL history-log writer. All local; no telemetry, no network.

### Acceptance criteria
- [ ] The full directory tree exists after launch and is user-discoverable in `~/Library/Application Support/Aide/`.
- [ ] `app.log` receives human-readable, timestamped entries; a JSONL history entry can be appended and read back.
- [ ] Writes are atomic (no partial/corrupt files on interruption). *(TDD: Persistence — tree creation, atomic write.)*
- [ ] Cross-phase gating checks pass.

---

## Phase 3: Config load/save/migration

**User stories**: config foundation (enables 13, 14, 29, 30 later)

### What to build
A schema-versioned `settings.json` model with load/save and forward-migration handling, stored via Phase 2's Persistence. Include at least one real, user-visible setting (e.g. an audio-cue toggle) to prove the round-trip. Secrets are excluded from the file by design (Keychain refs only).

### Acceptance criteria
- [ ] Changing a setting, quitting, and relaunching restores the changed value.
- [ ] A file written at an older `schema_version` migrates forward on load without data loss.
- [ ] A missing/corrupt settings file falls back to safe defaults rather than crashing. *(TDD: Configuration.)*
- [ ] Cross-phase gating checks pass.

---

## Phase 4: Overlay state machine + panel

**User stories**: 5, 6, 7, 10

### What to build
`OverlayState` — a pure state machine over Hidden ↔ Listening ↔ Processing ↔ ShowingResult / PromptBack / ConfirmBack — and a non-activating `NSPanel` (SwiftUI) bound to it. Drive it from temporary debug menu items that force each state. The panel must never become key/main.

### Acceptance criteria
- [ ] Debug triggers move the overlay through Listening → Processing → ShowingResult, PromptBack, and ConfirmBack visuals.
- [ ] With another app focused, showing the overlay **does not steal focus** (verify by keeping a text field's cursor active).
- [ ] Every legal transition and illegal-transition guard is covered. *(TDD: OverlayState.)*
- [ ] Cross-phase gating checks pass.

---

## Phase 5: Global hotkey capture

**User stories**: 11, 12, 15

### What to build
A `HotkeyManager` that installs a `CGEventTap` and translates raw keyDown/keyUp into semantic push-to-talk down/up for the two bound hotkeys (defaults ⌥Space / ⌃Space, read from Configuration). The menubar status reflects the hold. If Accessibility isn't granted, surface a clear message instead of failing silently. The tap callback returns immediately.

### Acceptance criteria
- [ ] Holding a hotkey from **any** foreground app updates the menubar to a "listening" state for the hold; release returns to idle.
- [ ] Both hotkeys are distinguished (command vs dictation) and read their bindings from settings.
- [ ] With Accessibility not granted, the app shows an actionable message rather than doing nothing.
- [ ] Binding logic (settings → chords; event → semantic hotkey) is unit-tested. *(TDD: HotkeyManager binding.)*
- [ ] Cross-phase gating checks pass.

---

## Phase 6: Wire hotkey → overlay → mock loop *(marquee)*

**User stories**: 2, 8, 39, 40, 41

### What to build
Introduce the `AideCore` **voice-session driver** protocol and a **mock** conformer. Wire Phase 5's hotkey to Phase 4's overlay: hotkey down → Overlay Listening (+ optional audio cue) → release → Processing → the mock yields a transcript + result → ShowingResult → auto-hide. The menubar mirrors the state. This is P1's end-to-end acceptance demo with inference mocked.

### Acceptance criteria
- [ ] Pressing and holding a hotkey shows Listening; releasing shows a mock transcript then a mock result in the overlay, then hides.
- [ ] Menubar and overlay both reflect the state; optional audio cue fires on listen.
- [ ] The loop runs without stealing focus from the frontmost app.
- [ ] The real inference can later replace the mock by conforming to the same protocol, with no change to overlay/hotkey/coordinator code (verified by the seam boundary).
- [ ] Cross-phase gating checks pass.

---

## Phase 7: Permission detection + graceful degradation

**User stories**: 25, 26, 27

### What to build
`PermissionGate` — prompt-free status detection for Microphone, Accessibility, Screen Recording, and Calendar; a mapping from each status to a fix-it hint + System Settings deep-link; and the per-permission degradation map (a denied permission disables only its dependent features). Wire the AX case so a denied hotkey path shows a fix-it in the menubar/overlay instead of silent failure.

### Acceptance criteria
- [ ] Each permission's status is read independently **without** triggering a system prompt.
- [ ] Revoking Accessibility surfaces a fix-it hint with a deep-link that opens the exact System Settings pane; re-granting recovers the feature.
- [ ] A denied permission disables exactly its dependent features and nothing else. *(TDD: PermissionGate — status→hint/deep-link mapping, degradation map.)*
- [ ] Cross-phase gating checks pass.

---

## Phase 8: Settings framework + Permissions pane

**User stories**: 28, 31, 32

### What to build
Generalize the Settings window into a **framework** that later pillars can register panes into. Ship the first pane: a Permissions view listing each permission with its live status (from `PermissionGate`) and a fix-it deep-link.

### Acceptance criteria
- [ ] Settings presents a pane structure that a new pane can be registered into without rebuilding the framework.
- [ ] The Permissions pane shows true current statuses and its deep-links open the correct System Settings panes.
- [ ] Cross-phase gating checks pass.

---

## Phase 9: Settings — hotkey rebind + overlay/indicator options

**User stories**: 13, 14, 29, 30

### What to build
A hotkey-rebinding pane that records a new chord and makes it take effect immediately via `HotkeyManager` (persisted through Configuration). An overlay/indicator options pane: overlay position, audio-cue toggles, and show/hide plus render of the **Local/Cloud indicator** (rendered as LOCAL by default in P1; its state is driven by P6 later).

### Acceptance criteria
- [ ] Rebinding a hotkey updates the active binding without relaunch and persists across relaunch.
- [ ] Overlay position / audio-cue toggles take effect and persist; the Local/Cloud indicator renders (default LOCAL).
- [ ] Cross-phase gating checks pass.

---

## Phase 10: Onboarding first-run flow

**User stories**: 16, 17, 18, 19, 20, 21, 22, 23, 24

### What to build
The ordered first-run walkthrough: welcome + one-paragraph privacy promise → RAM detection + proposed Tier confirm/override (model-download step is a **wired placeholder** for P2) → permissions **one at a time**, each with a plain-language "why," deep-link, and **auto-advance on detected grant** → **one-time** disclosure of the two keyless utility calls → hotkey setup (reuses Phase 9's binder) → guided first success (using Phase 6's mock loop) → graceful-degradation summary. The flow is resumable and lets the user skip optional permissions (Calendar).

### Acceptance criteria
- [ ] A fresh launch (cleared first-run state) walks the full ordered flow.
- [ ] Each permission step auto-advances once the grant is detected after returning from System Settings.
- [ ] Optional (Calendar) is skippable; quitting mid-flow resumes at the last step.
- [ ] The utility-call disclosure appears exactly once and persists its acknowledgement.
- [ ] Guided first success triggers the mock loop and shows a result. *(TDD: Onboarding flow — step advancement on injected grant events, resume, skip.)*
- [ ] Cross-phase gating checks pass.

---

## Phase 11: Wipe history + confirmation-modal infra + resilience polish

**User stories**: 34, 38

### What to build
A one-click "Wipe all history" in Settings that clears transcripts, command history, and script logs — but **not** settings, scripts, or dictionary unless separately chosen. The separate, focus-taking **ConfirmationModal** window mechanism (infrastructure for later destructive/typed confirmation), with a sample trigger to verify it. Resilience polish: ensure P1 failure paths surface human-readable states, and behavior across sleep/wake is sane.

### Acceptance criteria
- [ ] Wipe history removes exactly the in-scope files (transcripts/command-history/script-logs) and leaves settings/scripts/dictionary intact. *(TDD: wipe-scope correctness.)*
- [ ] The ConfirmationModal takes focus and requires a distinct, deliberate action (verified via a sample trigger).
- [ ] Every P1 failure path surfaces a human-readable state (no silent failures); the app resumes cleanly after sleep/wake.
- [ ] Cross-phase gating checks pass.

---

## Execution notes

- Phases are implemented **one at a time**; do not batch them.
- After each phase, pause for user review; apply feedback; proceed only on approval.
- Debug/temporary triggers introduced in early phases (e.g. Phase 4's state-forcing menu items) are removed or gated once the real driver (Phase 6) and onboarding (Phase 10) exercise those paths.
