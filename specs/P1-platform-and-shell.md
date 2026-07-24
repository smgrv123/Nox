# PRD — P1 · Platform & Shell

> Pillar P1 of Aide (see [`docs/07-implementation-pillars.md`](../docs/07-implementation-pillars.md)).
> Grounded in [`docs/04-hld.md`](../docs/04-hld.md) §13–16 and [`docs/05-lld.md`](../docs/05-lld.md) §2.5–2.7, §8–10.
> Status: draft spec · not yet planned.

## Problem Statement

Aide is a menubar voice assistant, but before any voice feature can exist there must be a **shell**: a thing that lives in the menubar, listens for a global hotkey no matter which app is focused, shows the user what state it's in without stealing their keyboard focus, walks a first-time user through the macOS permissions the app can't function without, remembers the user's preferences, and stores its data somewhere discoverable. None of that is a "feature" a user asks for by name — but if any of it is broken or missing, every feature built on top is unreachable. A broken first-run (a permission the user can't figure out how to grant, an app with no visible feedback) kills the product before it starts.

This pillar has no AI in it. Its job is to be the reliable, always-on foundation that the inference and feature pillars plug into.

## Solution

A native macOS **menubar-only app** (no Dock icon) that:

- shows a menubar presence with live status and a menu into Settings;
- floats a lightweight, **non-activating Overlay** that reports listening/processing/result state and never steals focus from the app the user is working in;
- captures two configurable **global push-to-talk hotkeys** (command mode, dictation mode) system-wide;
- runs a **one-at-a-time permission onboarding** walkthrough — each permission with a plain-language "why," a deep-link to the exact System Settings pane, and automatic advancement once the grant is detected — and degrades gracefully when a permission is denied;
- persists preferences and data under `~/Library/Application Support/Aide/` in human-readable files, with a one-click "wipe history";
- enforces a single running instance and keeps sane behavior across sleep/wake.

Because the inference and routing pillars (P2/P4) don't exist yet, P1 is built against **interface seams** (protocols in `AideCore`) with **mock** implementations, so the whole "press hotkey → Overlay shows Listening → a result appears" loop is demoable and testable today. When P2/P4 arrive, they satisfy the same protocols with real implementations and no P1 code changes.

## User Stories

### Menubar presence & feedback
1. As a user, I want Aide to live in the menu bar with no Dock icon, so that it stays out of my way while remaining reachable.
2. As a user, I want the menubar icon to reflect Aide's current state (idle, listening, processing), so that I always know whether it's hearing me.
3. As a user, I want a menu from the menubar icon with status, a Local/Cloud indicator, and an entry into Settings, so that I can check and control Aide quickly.
4. As a user, I want to quit Aide from the menubar menu, so that I can stop it deliberately.

### Overlay & listening feedback
5. As a user, I want a floating overlay to appear when the mic is hot, so that I have unambiguous confirmation Aide is listening.
6. As a user, I want the overlay to show transcription-in-progress and the resulting action/answer, so that I can see what Aide understood.
7. As a user, I want the overlay to **never steal keyboard focus** from the app I'm typing in, so that dictation and text insertion land in the right place.
8. As a user, I want an optional audio cue when listening starts (and optionally when processing), so that I can use Aide without watching the screen.
9. As a user, I want the overlay to show a "did you mean…?" prompt-back when Aide is unsure, so that I can correct it rather than have it guess.
10. As a user, I want listening-state feedback in **both** the menubar and the overlay, so that the cue is visible wherever I'm looking.

### Hotkeys
11. As a user, I want to hold a global hotkey to talk (push-to-talk) from any app, so that I can invoke Aide without switching windows.
12. As a user, I want two distinct hotkeys — one for command mode, one for dictation mode — so that I control which behavior I trigger.
13. As a user, I want sensible default hotkeys offered during setup, so that I can start immediately without configuring anything.
14. As a user, I want to rebind either hotkey in Settings, so that I can avoid conflicts with my other shortcuts.
15. As a user, I want a clear message if the hotkey can't be captured (Accessibility not granted), so that I know how to fix it instead of it silently doing nothing.

### Onboarding
16. As a first-time user, I want a welcome screen with a one-paragraph plain-language privacy promise, so that I understand "local unless I say otherwise" before granting anything.
17. As a first-time user, I want Aide to detect my RAM and propose a model tier that I can confirm or override, so that it's tuned to my machine. *(The tier confirmation UI is P1; the actual model download is P2 and appears here as a wired placeholder.)*
18. As a first-time user, I want each permission requested **one at a time**, each explaining *why* it's needed, so that I'm not overwhelmed by a wall of system prompts.
19. As a first-time user, I want a button that deep-links me straight to the exact System Settings pane for each permission, so that I don't have to hunt through System Settings.
20. As a first-time user, I want Aide to detect the moment I grant a permission and advance automatically, so that the flow feels responsive.
21. As a first-time user, I want to skip optional permissions (e.g. Calendar), so that I'm not forced to grant things I don't want.
22. As a first-time user, I want to be told **once** that Aide makes two keyless network calls (weather, currency), so that the only implicit network traffic is disclosed without nagging me later.
23. As a first-time user, I want a guided first success ("Hold the hotkey and say: open Safari"), so that I experience a win before being left on my own.
24. As a first-time user, I want to resume onboarding where I left off if I quit midway, so that I don't restart from scratch.

### Permissions & graceful degradation
25. As a user, I want a denied permission to disable **only** the features that need it — not break the whole app — so that partial grants still leave me a working product.
26. As a user, I want a persistent, actionable fix-it hint in Settings for any denied permission, so that I can grant it later without confusion.
27. As a user, I want Aide to detect each permission's status independently without triggering a prompt, so that Settings always shows me the true current state.

### Settings (shell + P1 panes)
28. As a user, I want a Settings window I can open from the menubar, so that I can configure Aide.
29. As a user, I want a Settings pane to rebind my hotkeys, so that I control my triggers.
30. As a user, I want a Settings pane for overlay/indicator options (position, audio cues, show/hide the Local/Cloud indicator), so that the feedback fits my preference.
31. As a user, I want a Settings pane listing each permission with its status and a fix-it deep-link, so that I can manage grants in one place.
32. As a user, I want later feature pillars to add their own Settings panes without the Settings framework being rebuilt, so that the app grows cleanly.

### Storage, history & wipe
33. As a user, I want all of Aide's data under `~/Library/Application Support/Aide/` in human-readable files, so that I can find, inspect, and back it up.
34. As a user, I want a one-click "Wipe all history" that clears transcripts, command history, and script logs — but **not** my settings, scripts, or dictionary unless I choose — so that I can clear my trail without losing my configuration.
35. As a user, I want Aide's logs to be plain, local, human-readable text with zero telemetry, so that I can trust nothing is phoned home.

### Resilience & lifecycle
36. As a user, I want only one instance of Aide to run at a time, so that two copies don't fight over the mic, hotkeys, or ports.
37. As a user, I want Aide to behave sanely across sleep/wake, so that it keeps working after my Mac wakes up.
38. As a user, I want every failure to surface as a human-readable state rather than silence, so that I'm never left wondering why nothing happened.

### Developer-facing (pillar consumers)
39. As a developer building P4/P5/P6, I want P1 to expose a stable protocol seam for driving a voice session (start listening → transcript → result), so that my pillar plugs in without changing P1.
40. As a developer, I want P1 built and demoable against a mock implementation of that seam, so that the shell is proven before the real inference exists.
41. As a developer, I want the Overlay state machine, permission gate, settings/persistence, and onboarding flow to be unit-testable in isolation, so that the foundation is trustworthy.

## Implementation Decisions

**Shared contract layer (already exists).** `AideCore` holds shared value types (`RiskTier`, `ScanVerdict`, `AideError`) and the interface **protocols** P1 renders against. P1 adds the seam(s) it needs — notably a **voice-session driver** protocol (given a hotkey activation, yields a listening→transcript→result stream) — and ships a **mock** conformer. Real STT/routing (P2/P4) satisfy the same protocol later with no P1 change.

**Modules (deep, isolated where possible):**

- **OverlayState** — a pure state machine over the Overlay's states (Hidden ↔ Listening ↔ Processing ↔ ShowingResult / PromptBack / ConfirmBack). No UI, no I/O. This is the deep, testable heart of the Overlay.
- **OverlayPanel** — the non-activating `NSPanel` + SwiftUI rendering, bound to `OverlayState`. A thin view shell; its one hard requirement is *never becoming key/main* (no focus stealing).
- **MenubarController** — the `MenuBarExtra` menu + status/indicator rendering. Thin UI shell.
- **ConfirmationModal** — infrastructure for a *separate, ordinary, focus-taking* modal window used later (P3/P4) for typed/destructive confirmation. P1 provides the mechanism; the destructive content comes later.
- **HotkeyManager** — installs the `CGEventTap` and translates raw keyDown/keyUp into semantic push-to-talk down/up events for the two bound hotkeys. The binding logic (settings → registered chords; event → semantic hotkey) is testable; the tap install itself is OS-bound.
- **PermissionGate** — independent, prompt-free status detection for Microphone, Accessibility, Screen Recording, and Calendar; maps each status to a fix-it hint + System Settings deep-link; owns the per-permission graceful-degradation map.
- **Onboarding** — the first-run flow coordinator: an ordered step machine (welcome → tier confirm → [model-download placeholder] → permissions one-at-a-time → utility disclosure → hotkey setup → guided first success), advancing on observed grant events, with skip handling for optional steps and resumability.
- **Configuration** — the settings model, schema-versioned, with load/save and forward-migration handling.
- **Persistence** — owns the Application Support directory tree, atomic writes, and the scoped "wipe history" operation.
- **Logging** — plain-text `app.log` plus append-only JSONL history/command logs; local only.
- **AppCoordinator** — app lifecycle wiring, single-instance enforcement, sleep/wake handling.

**Settings scope (locked):** P1 builds the **Settings framework + only P1-owned panes** (hotkeys, overlay/indicators, permission fix-its, wipe history). Later pillars register their own panes (BYOK, Tone, Tier, dictionary) into the framework; P1 does not build dead UI for them.

**Settings document:** a single schema-versioned `settings.json` under Application Support, holding hotkey bindings, indicator/overlay options, and the privacy-disclosure + wipe-scope defaults. Secrets (e.g. a future BYOK key) are **never** in this file — they go to the macOS Keychain, referenced by a `keychain://` URI. Fields owned by later pillars (tier, tone, BYOK, wake word) exist in the schema with safe defaults but are surfaced by those pillars' panes, not P1.

**Storage layout:** everything under `~/Library/Application Support/Aide/` — settings, dictionary, skill registry, user scripts, transcripts/command history, execution logs; downloaded models live under a user-discoverable models directory (final Application Support vs. Caches placement per LLD). Logs are plain, human-readable, append-only. Zero telemetry.

**Hotkey defaults:** command mode = ⌥Space, dictation mode = ⌃Space, both push-to-talk; user-rebindable. Push-to-talk is the flow-control mechanism (one utterance in flight; a new press while processing cancels the prior).

**Permissions & detection:** Microphone (`AVCaptureDevice` status), Accessibility (`AXIsProcessTrusted`; cannot be prompted programmatically — must guide + deep-link), Screen Recording (`CGPreflightScreenCaptureAccess`), Calendar/EventKit (optional). Each detected independently and prompt-free; onboarding polls status after the user returns from System Settings and auto-advances on grant.

**Entitlements / hardened runtime (day one; signing a later flip):** Hardened Runtime on; `device.audio-input`; `automation.apple-events`; `cs.disable-library-validation` (native libs / bundled sidecar later); `cs.allow-jit` as required; **App Sandbox off** (v1 — needs screencapture, arbitrary text insertion, launchd agents, local sidecar; revisited only if App Store ever becomes a target, which it is not). Sidecar (later) binds loopback only.

**Concurrency rules (MUST):** all `AXUIElement` and `CGEvent.post` calls and all overlay/menubar UI updates run on the main actor; the `CGEventTap` callback returns immediately and only signals capture start/stop (no heavy work in the tap); single-instance enforced at launch.

**No-network invariant:** P1 performs **no** network I/O of its own. (Model downloads are P2; utility calls are P6.) This keeps the foundation trivially offline-correct.

## Testing Decisions

**Approach: TDD (red-green-refactor), tests-first**, for the deep modules — write the failing test that expresses the desired external behavior, make it pass, then refactor.

**What makes a good test here:** it exercises **external behavior through the module's public interface**, not internal implementation details. Tests feed inputs and assert outputs/state, and must not break when internals are refactored. Time, permission status, and grant events are injected (not read from the live OS) so tests are deterministic and headless.

**Modules under test (all four deep modules):**
- **OverlayState** — every legal transition and the illegal-transition guards; e.g. a new activation while `Processing` cancels and restarts; `ConfirmBack` → approved vs rejected outcomes.
- **PermissionGate** — status → fix-it/deep-link mapping for each permission; the degradation map (denied permission disables exactly its dependent features, nothing more); optional-permission skip.
- **Configuration / Persistence** — settings load/save round-trip; schema-version forward migration; atomic-write behavior; and the **wipe-scope correctness** rule (wipe clears transcripts/command-history/script-logs but leaves settings, scripts, and dictionary untouched unless explicitly chosen).
- **Onboarding** — step advancement on injected grant events; resume-from-last-step; skip handling for optional permissions.

**Not unit-tested (verified manually / by running the app):** the SwiftUI/`NSPanel`/`MenuBarExtra` rendering shells and the actual `CGEventTap` install — these are thin OS-bound shells around the tested logic. The Overlay's **non-activating (no focus steal)** property is verified manually by dictating into another app while the overlay is visible.

**Prior art:** the `DangerousCommandScanner` module already in the repo (`Sources/DangerousCommandScanner` + its XCTest suite) is the pattern to follow — a pure module behind a small interface, exhaustively tested headlessly via `swift test`, with the app target depending on it.

## Out of Scope

- Real STT and LLM inference — **P2** (P1 uses a mock behind the seam).
- Routing, the Skill Registry, dispatch, and built-in skills — **P4**.
- Dictation, tone cleanup, text insertion, personalization dictionary — **P5**.
- General-Knowledge / Screen Q&A, session context, cloud/BYOK offload, and *driving* the Local/Cloud indicator (P1 renders the indicator component, defaulting to LOCAL; its state is driven by P6) — **P6**.
- User script-automations and scheduling — **P7**.
- The **actual** resumable model-download implementation — **P2** fills P1's onboarding placeholder.
- BYOK / Tone / Tier / dictionary Settings panes — registered by their owning pillars into P1's Settings framework.
- Wake word (experimental, off by default) — a later, opt-in addition.
- Automatic edit-detection for the dictionary — deferred (explicit-only in v1, and owned by P5 regardless).
- Code signing / notarization — configuration is present day one; the actual signed/notarized build is a later flip.

## Further Notes

- **Independence via contracts:** P1 depends on no other *feature* pillar. It sits directly on `AideCore` (shared types + protocol seams) and is built/tested against mocks. This is what lets it ship and be verified before P2–P7 exist; the "core" beneath P1 is only `AideCore`, which is plumbing, not a pillar.
- **Demoability target ("done"):** launch as a menubar app → complete the permission walkthrough → press a hotkey → Overlay shows Listening → a **mock** transcript and result render → settings persist across relaunch → wipe-history works. That end-to-end (with the inference mocked) is P1's acceptance demo.
- **Relevant NFRs (design toward, not hard gates):** near-zero idle CPU; the Overlay and hotkey path must feel instant; every failure surfaces a human-readable state; single-instance; sane sleep/wake.
- **Reference machine:** Apple M2 / 16GB, macOS 14+, Apple Silicon only.
- This PRD is the input to the P1 **phased plan** (tracer-bullet slices), authored next.
