# Aide — Implementation Pillars

This document breaks the whole Aide build into **7 pillars across two tiers**: three
horizontal **foundations** that everything sits on, then four vertical **capability**
pillars that each deliver a user-facing feature. Each pillar is independently buildable,
has a clear interface boundary, and maps to specific HLD/LLD sections so that a **spec**
(scoped requirements + interfaces) and a **phased plan** (tracer-bullet slices) can be
authored per pillar.

Source docs: [`01-problem-to-solve.md`](./01-problem-to-solve.md) ·
[`03-architecture.md`](./03-architecture.md) · [`04-hld.md`](./04-hld.md) ·
[`05-lld.md`](./05-lld.md) · [`06-walkthrough.md`](./06-walkthrough.md).

---

## Tier A — Foundations (build first; they enable everything)

### P1 · Platform & Shell
The always-on skeleton every feature plugs into.

| | |
|---|---|
| **Contains** | Menubar app (`MenuBarExtra`); non-activating `NSPanel` **Overlay** + **Listening States**; global hotkeys (**CGEventTap**); onboarding + **TCC** permission walkthrough; **Settings**; storage layout (**Application Support**); local logging. |
| **HLD / LLD** | HLD §13–16; LLD §2.5–2.7, §8, §10 |
| **Depends on** | — (nothing) |
| **Exposes** | Overlay/state API, hotkey down/up events, settings store, permission-status queries |
| **Done =** | App launches as a menubar item, walks permissions, shows the Overlay, and routes hotkey down/up events. *(tracer bullet already started)* |

### P2 · Inference Core
The engine: audio→text and prompt→text, nothing else.

| | |
|---|---|
| **Contains** | **whisper.cpp** in-process **STT** + **Whisper Segment-Probability Pre-Gate**; **llama-server Sidecar** lifecycle (spawn/health/restart/dynamic port); the single **OpenAI-compatible client** (local + BYOK); model download/verify (pinned SHA + SHA-256)/**Tier**/**Model Residency**. |
| **HLD / LLD** | HLD §3–4; LLD §3.2–3.4, §4.1, §5.1, §5.4 |
| **Depends on** | — (integrates with P1 for UI later) |
| **Exposes** | `transcribe(audio) → (text, segment probs)`; `complete(prompt, grammar?) → (text, logprobs)` |
| **Done =** | CLI/integration test: sample audio → transcript; a prompt → completion with logprobs, both local and cloud. |

### P3 · Safety Guard
The deterministic scanner, isolated so every consumer shares one guard.

| | |
|---|---|
| **Contains** | **Dangerous-Command Scanner** (Swift, in-process, recursive descent into pipes/`$()`/backticks/`sh -c`; **Hard-Block** vs **Confirm** tiers); **Scanner Scope** rules; confirmation surfaces. |
| **HLD / LLD** | HLD §8; LLD §4.3, §11 |
| **Depends on** | Shared types only — nearly standalone. ***Module + tests already started.*** |
| **Exposes** | `scan(command, context) → verdict` |
| **Done =** | Correctly classifies a corpus of malicious/benign commands (tests green), including nested/obfuscated cases. |

---

## Tier B — Capabilities (vertical features on the foundations)

### P4 · Command Routing & Skills
Speak a command; a built-in skill runs.

| | |
|---|---|
| **Contains** | **Router Contract v2**; **GBNF Grammar** generation from the **Skill Registry**; **Logprob-Derived Routing Confidence** gate; schema validation; **Risk Tiers**; **Dispatch**; **Manifest** format + registry; built-in skills (open/quit app, timer, media, screenshot, weather, time/date, calc, calendar-read). Reserved router targets `general_qa`/`screen_qa` are wired here (consumed by P6). |
| **HLD / LLD** | HLD §5–6, §7.1; LLD §2.1–2.2, §3.1, §4.2, §4.4 |
| **Depends on** | **P1, P2, P3** |
| **Done =** | "open Safari" → routes → executes; prompt-back and Confirm-Back paths both work. |

### P5 · Dictation
The hero feature: talk into any app, cleaned up. Split into **P5a · Dictation Core** and **P5b · Personalization Dictionary** (same split as P2a/P2b). Specs: [`specs/P5a-dictation-core.md`](../specs/P5a-dictation-core.md), [`specs/P5b-personalization-dictionary.md`](../specs/P5b-personalization-dictionary.md). Plans: [`plans/P5a-dictation-core.md`](../plans/P5a-dictation-core.md), [`plans/P5b-personalization-dictionary.md`](../plans/P5b-personalization-dictionary.md).

### P5a · Dictation Core
Hold ⌃Space → transcribe → optional tone cleanup → insert at the caret.

| | |
|---|---|
| **Contains** | Hotkey B capture → transcribe → single **tone-aware cleanup pass** (**Tone Presets**) → **Text Insertion** (paste-only: synthetic ⌘V with clipboard save/restore and clipboard-manager skip markers, Secure-Input preflight, copy-to-clipboard escape, terminal-destination scan via P3 C11) → Settings (`tone`, `dictation.cleanup_enabled`) → raw bypass when the sidecar is not ready. |
| **HLD / LLD** | HLD §9, §18.2; LLD §2.5, §3.5, §4.6–4.7, §6.3, §8–10 |
| **Depends on** | **P1, P2, P3** (P4 merged to `main` but not a logic dependency) |
| **Done =** | Dictate into a standard app and into a terminal — cleaned (or raw on bypass), inserted, with Confirm-Back on terminal input. |

> **AX insertion was removed during implementation** — see ADR **A8** in [`03-architecture.md`](./03-architecture.md). `AXUIElementSetAttributeValue(…, kAXSelectedTextAttribute, …)` reports success on *acceptance*, not insertion, so Electron/Catalyst/custom text views accepted and discarded it; it had zero confirmed successes in real use. With AX gone, `InsertionPlanner`, `AppInsertionOverride`, `InsertionPlan`, `TerminalBundleAllowlist` and per-app override learning went with it. Accessibility permission is still required — synthetic ⌘V needs it. The P5a spec and plan carry an amendment banner recording the same reversal.

### P5b · Personalization Dictionary
Explicit-only vocabulary store consumed by Whisper and cleanup.

| | |
|---|---|
| **Contains** | `dictionary.json` (LLD §2.3) + MRU cap 500; **"correct that"** builtin skill; Whisper **bias prompt** (real tokenizer, 200-token budget, merged with P4 app-name bias); cleanup-prompt **substitution** list (top 40); Dictionary Settings pane. |
| **HLD / LLD** | HLD §9.3, §15.2; LLD §2.3, §4.5, §6.3 |
| **Depends on** | **P4** (registry/GBNF/executor), **P5a** (prompt slots) |
| **Done =** | "correct that: X should be Y" → next dictation is biased and substitutions apply; wipe-history spares the dictionary. |

### P6 · Assistant Intelligence
Ask about the world and about the screen.

| | |
|---|---|
| **Contains** | **General-Knowledge Q&A** (local answering, **⟨UNSURE⟩** honesty flow); **Screen Q&A** (`screencapture` → Vision **OCR** with **Bounding Boxes** → prompt); **Session Context** + automatic continuation detection; **Cloud Escalation/BYOK** offload + **Local/Cloud Indicator**. |
| **HLD / LLD** | HLD §10–12; LLD §2.4, §6 |
| **Depends on** | **P1, P2, P4** (reserved targets `general_qa` / `screen_qa`) |
| **Feeds** | **Session Context** also feeds the P5a dictation cleanup prompt (LLD §6.3, currently preset instruction + dictionary substitutions + raw transcript only) — dictation itself holds no cross-utterance buffer, so consecutive dictated utterances don't cohere on their own; that's deliberate, since cross-utterance coherence is solved once here rather than with a dictation-local buffer. |
| **Done =** | Confident local answer; uncertain → consent-gated offload; a follow-up that uses context; a screen question answered from OCR. |

### P7 · Automations & Scheduling
The extensibility engine.

| | |
|---|---|
| **Contains** | **User Script-Automations** (voice → generate [cloud-preferred] → shown in full → **Scanner** → explicit approval → **Frozen Script**) → **launchd Agent** registration; execution guardrails (per-run timeout, local stdout/stderr logs, **auto-disable after N consecutive failures**). |
| **HLD / LLD** | HLD §6–7; LLD §2.1 (schedule/failure state), §5.3 |
| **Depends on** | **P1, P2, P4** (shared registry/manifest), **P3** (critical) |
| **Done =** | Create + schedule a recurring automation safely; it fires and logs; it auto-disables after repeated failure with a notification. |

---

## Build order & parallelism

```
P1 ─┐
P2 ─┼─→ P4 ─┬─→ P6
P3 ─┘        └─→ P7
             P5  (needs P1, P2, + P3)
```

- **Wave 1 (parallel):** P1, P2, P3 — no inter-dependencies; P1 and P3 are already begun.
- **Wave 2:** P4 — ties the command loop together (router + registry + dispatch).
- **Wave 3 (parallel):** P5, P6, P7 — all sit on the Wave-1 / Wave-2 foundations.

## Next step (per pillar)

Each pillar gets, in order:
1. a **spec** — scoped requirements + module interfaces, drawn from the HLD/LLD; then
2. a **phased plan** — tracer-bullet vertical slices to build it incrementally.

## Current status

| Pillar | Status |
|---|---|
| P1 Platform & Shell | **Complete** — all 11 phases shipped (`plans/P1-platform-and-shell.md`) |
| P2 Inference Core | **Complete** — P2a · Speech-to-Text (all 5 phases) + P2b · LLM Runtime (all 6 phases) shipped |
| P3 Safety Guard | **Complete** — all 6 phases shipped (`plans/P3-safety-guard.md`); recursive-descent scanner with 370 tests |
| P4 Command Routing & Skills | **Complete** — headless Phases 1–7 (`plans/P4-command-routing-and-skills.md`) plus app-wiring Phases 1–6 (`plans/P4-app-wiring.md`) |
| P5a Dictation Core | **Complete** — all 5 phases shipped on `feat/p5a-dictation-core` (`plans/P5a-dictation-core.md`); insertion is paste-only per ADR A8 |
| P5b Personalization Dictionary | **Spec + plan authored** — implementation not started (`plans/P5b-personalization-dictionary.md`); execute after P5a |
| P6, P7 | Not started |
