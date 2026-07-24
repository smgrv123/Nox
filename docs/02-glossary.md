# Aide — Glossary (Ubiquitous Language)

> **Status:** Authoritative. This document defines the canonical vocabulary ("ubiquitous language") for the Aide project. Every other document in this set —
> [`01-problem-to-solve.md`](01-problem-to-solve.md), [`03-architecture.md`](03-architecture.md), [`04-hld.md`](04-hld.md), [`05-lld.md`](05-lld.md), and [`06-walkthrough.md`](06-walkthrough.md) — MUST use these terms as defined here. Where a term below conflicts with a casual usage in the source PRD, this glossary and the Locked Decisions it encodes win.

---

## 1. Purpose & Conventions

This glossary is the single source of truth for Aide's domain vocabulary. Its goal is that any implementation agent or reviewer reading any sibling document interprets a term identically.

**Reading conventions used throughout the doc set:**

- **Canonical term** — the exact bolded name is the one to use in code identifiers (adapted to the language's casing), UI copy, commit messages, and prose. Synonyms are listed but discouraged.
- **"Not to be confused with:"** — flags a term that is frequently conflated with the one being defined, and states the distinction.
- **"See also:"** — cross-links to related canonical terms in this glossary.
- **Locked Decision** — a decision that is non-negotiable for v1. Where a definition encodes one, it is marked `(Locked)`. The authoritative amendments (notably **Router Contract v2**) OVERRIDE any conflicting PRD default, including the PRD's "locked" §6.
- **Assumption** — where the PRD is silent and this glossary makes a reasonable, PRD-consistent choice, it is marked `(Assumption)` so downstream docs can trace it.
- **Tier notation** — `16GB tier` and `8GB tier` refer to the two model-tiering profiles (see **Tier**). The reference machine is Apple M2 / 16GB.

**Casing convention for identifiers (Assumption):** skill IDs, intents, and manifest keys are `lower_snake_case`; Swift types are `UpperCamelCase`; the sentinel and mode names appear in UI as written here.

**Scope:** Apple Silicon only, macOS 14+ `(Locked)`. Any term implying Intel, Windows, iOS, or a VLM describes something explicitly **out of scope** for v1.

---

## 2. Core Product Concepts

**Aide** — A local-first, native macOS menubar application that lets a user control their Mac by voice, dictate tone-rewritten text into any app, ask questions about on-screen content, and create scheduled automations, with **all inference running locally**. Aide is a *deterministic skill system with an LLM acting purely as a router and text processor* — it is explicitly **not** an autonomous agent and the LLM never freely controls the screen. *Not to be confused with:* a general "AI agent" or a cloud assistant; Aide's only implicit network traffic is one-time model downloads and two disclosed keyless utility calls. *See also:* **Local-First**, **Router**, **Skill**.

**Command Mode** — The interaction mode entered by holding **Hotkey A**: the user's speech is transcribed and routed to a **Skill** (or answered as **General Knowledge Q&A** / **Screen Q&A**). Command Mode is the "do something / ask something" mode. *Not to be confused with:* **Dictation Mode** (which inserts text and never routes to a skill). *See also:* **Router**, **Dispatch**, **Hotkey A**.

**Dictation Mode** — The interaction mode entered by holding **Hotkey B**: the user's speech is transcribed, passed through a single tone-aware **Cleanup Pass**, and inserted at the text cursor via **Text Insertion**. This is the "hero feature." Dictation Mode never routes to a skill and never executes commands — but text dictated *into a terminal emulator* is still subject to the **Dangerous-Command Scanner** (see **Scanner scope**). *Not to be confused with:* Command Mode; raw transcription (dictation always applies a tone cleanup). *See also:* **Tone Preset**, **Cleanup Pass**, **AX-first**.

**Overlay** — A lightweight, floating, **non-activating `NSPanel`** rendered in SwiftUI `(Locked)` that displays live transcription, the router result, Screen Q&A answers, **Confirm-Back** prompts, and the **Local/Cloud Indicator**. "Non-activating" means showing the overlay never steals keyboard focus from the frontmost app, so **Text Insertion** targets the right element. *Not to be confused with:* the **Menubar App** menu (a separate `MenuBarExtra` menu). *See also:* **Listening State**, **Local/Cloud Indicator**.

**Menubar App** — Aide's primary presence: a menu-bar-resident app with **no Dock icon by default**, implemented as a `MenuBarExtra` that opens a *separate menubar menu* `(Locked)`. It surfaces status, settings access, and permission fix-it hints. *Not to be confused with:* the **Overlay** (a floating panel, not the menu). *See also:* **Single Instance**, **Listening State**.

**Sidecar** — See §4 (**Sidecar**). The sole out-of-process helper Aide manages.

**BYOK** — See §8 (**BYOK**). "Bring Your Own Key."

---

## 3. Interaction & Input

**Push-to-Talk (PTT)** — The **primary** input mechanism `(Locked)`: the microphone is hot only while a global hotkey is physically held down, and speech is processed on release (**Batch-on-Release**). Implemented by observing `keyDown`/`keyUp` via a **CGEventTap**. *Not to be confused with:* the **Wake Word** (a hands-free trigger that ships off by default). *See also:* **Hotkey A**, **Hotkey B**, **Listening State**, **CGEventTap**.

**Hotkey A** — The user-configurable global hotkey that engages **Command Mode** (route to skill / ask). Default offered during onboarding is `⌥Space` (Option-Space) `(Assumption, per PRD onboarding example)`. *See also:* **Command Mode**, **CGEventTap**.

**Hotkey B** — The user-configurable global hotkey that engages **Dictation Mode** (transcribe → tone cleanup → insert). *See also:* **Dictation Mode**, **Text Insertion**.

**CGEventTap** — The Core Graphics low-level event tap Aide installs to detect `keyDown`/`keyUp` for Push-to-Talk hotkeys `(Locked)`. Requires the **Accessibility** permission. *Not to be confused with:* a Carbon `RegisterEventHotKey` global shortcut (not used, because PTT needs explicit key-up). *See also:* **Accessibility / AX**, **TCC**.

**Wake Word** — An **experimental, off-by-default** hands-free trigger phrase using an off-the-shelf pre-trained model — **openWakeWord** `(Locked default)` (Porcupine is an acceptable alternative). No custom-phrase training in v1. Hotkeys remain fully functional whether or not the wake word is enabled; if enabled, audio-session conflicts (calls/music) are handled gracefully. *Not to be confused with:* Push-to-Talk (the primary, always-available path). *See also:* **Listening State**.

**Listening State** — The mandatory, user-visible feedback signalling microphone/processing status. It has at least three legible values — *idle*, *listening* (mic hot), and *processing* — surfaced via **Menubar App** and/or **Overlay** state, plus an optional audio cue. *Not to be confused with:* the **Local/Cloud Indicator** (which signals *where* inference runs, not *whether* the mic is hot). *See also:* **Overlay**, **Push-to-Talk**.

**Batch-on-Release** — The v1 STT capture strategy `(Locked)`: audio is buffered while the hotkey is held and transcribed as a single utterance on release. The audio buffer is architected so a later **streaming** STT mode can be added without redesign. *See also:* **STT**, **whisper.cpp**.

---

## 4. Models & Inference

**STT (Speech-to-Text)** — The subsystem that converts captured microphone audio into text, run **fully locally** via **whisper.cpp**. In v1 it operates **Batch-on-Release**. *See also:* **whisper.cpp**, **Tier**, **Whisper Bias Prompt**.

**whisper.cpp** — The C/C++ Whisper implementation used for STT, run **in-process** (linked into the app via SwiftPM, bridged through its C API) `(Locked)` — it is **not** a sidecar. Model variant is selected by **Tier**: `large-v3-turbo` on the 16GB tier; `small` or `medium` on the 8GB tier (the exact 8GB variant is a build-time calibration decision, since smaller Whisper variants degrade faster on non-English/code-mixed speech). *Not to be confused with:* **llama-server** (the LLM runtime, which *is* a sidecar). *See also:* **Whisper Segment-Probability Pre-Gate**, **Whisper Bias Prompt**.

**Whisper Bias Prompt** — The initial/prompt text fed to Whisper to bias recognition toward known correct spellings drawn from the **Personalization Dictionary**. It MUST respect Whisper's **~224-token prompt cap** `(Locked)`, prioritizing entries by recency/frequency. *Not to be confused with:* the **Cleanup Prompt** (an LLM prompt, applied *after* transcription). *See also:* **Personalization Dictionary**, **STT**.

**LLM (Large Language Model)** — The local language model that performs routing, dictation cleanup, general-knowledge answering, and screen-content answering. It acts *purely* as a router and text processor; it never freely controls the screen. Served via **llama-server**. *See also:* **Qwen3**, **Router**, **Cleanup Pass**, **OpenAI-compatible endpoint**.

**Qwen3** — The chosen local LLM family `(Locked)`. Tiered: **Qwen3-8B Q4_K_M** on the 16GB tier; **Qwen3-4B Q4_K_M** on the 8GB tier. Delivered as GGUF weights, not bundled in the `.app`. *See also:* **Tier**, **Model Residency**, **GGUF**.

**Sidecar** — The single out-of-process helper Aide spawns and supervises. In v1 the **only** sidecar is **llama-server** `(Locked)`. Aide manages its full lifecycle: spawn, health-check, backoff restart, and kill. *Not to be confused with:* **whisper.cpp** (in-process, not a sidecar). *See also:* **llama-server**, **Health Check**, **Backoff Restart**.

**llama-server** — The bundled, version-**pinned** `llama.cpp` server binary that is Aide's sole **Sidecar** `(Locked)`. It exposes an **OpenAI-compatible endpoint** on a **dynamically chosen localhost port**, is health-checked, and is restarted with backoff on crash. Model weights live under **Application Support**. *See also:* **Sidecar**, **Dynamic Localhost Port**, **OpenAI-compatible endpoint**.

**OpenAI-compatible endpoint** — The HTTP API shape (`/v1/chat/completions`, `/v1/completions`, etc.) exposed by **llama-server** and consumed by Aide's **single** HTTP client. The same client talks to local llama-server and to any cloud provider (OpenAI, Anthropic-compat, OpenRouter, Groq, a user's Ollama, …) by swapping base URL + key + model name. *See also:* **BYOK**, **Escalation / Offload**, **Logprob**.

**Dynamic Localhost Port** — The localhost TCP port chosen at runtime for the llama-server sidecar (not a fixed constant), to avoid collisions and multi-instance conflicts `(Locked)`. Aide discovers the port and uses it for all local LLM traffic and health checks. *See also:* **Health Check**, **Single Instance**.

**Health Check** — The periodic probe Aide issues against the llama-server sidecar to confirm liveness/readiness. A failed health check triggers **Backoff Restart**; the sidecar's readiness gates any LLM-dependent operation. *See also:* **Backoff Restart**, **Model Residency**.

**Backoff Restart** — The resilience policy for the sidecar: on crash or failed **Health Check**, Aide restarts llama-server with increasing back-off delays, surfacing a human-readable state, and **never taking the app down** `(Locked NFR)`. *See also:* **Sidecar**, **Resilience**.

**Tier** — The RAM-based model-selection profile chosen at first launch and overridable in settings `(Locked policy)`. **16GB tier** (≥16GB RAM): Whisper `large-v3-turbo` + Qwen3-8B Q4_K_M; the LLM stays resident. **8GB tier**: Whisper `small`/`medium` + Qwen3-4B Q4_K_M; the LLM unloads after an idle timeout to reclaim RAM. *Not to be confused with:* **Risk Tier** (a per-manifest safety classification — unrelated). *See also:* **Model Residency**, **Idle Timeout**.

**Model Residency** — Whether a model's weights are currently loaded in RAM. On the **16GB tier** the LLM stays resident, so follow-ups are instant. On the **8GB tier** the LLM unloads after an **Idle Timeout**; a subsequent request triggers a reload with a *visible brief loading state* — never a failure or dropped context. *See also:* **Tier**, **Session Context**, **Idle Timeout**.

**GGUF** — The on-disk quantized weight file format used for Qwen3 models loaded by llama-server. `Q4_K_M` denotes the 4-bit quantization scheme used for both tiers. `(Assumption: format named for downstream clarity.)` *See also:* **Qwen3**, **Model delivery**.

**GBNF Grammar** — A GGML/llama.cpp **B**ackus–**N**aur-**F**orm grammar that constrains the LLM's token generation so output is guaranteed to conform to a shape (e.g., valid **Router Contract v2** JSON) `(Locked)`. The router prompt + GBNF grammar are **generated from the Skill Registry**, not hand-maintained. Grammar constraint also causes the model to **renormalize logprobs** over only the grammar-legal tokens — a fact the **Logprob-Derived Routing Confidence** measurement accounts for. *Not to be confused with:* **Schema Validation** (a post-generation deterministic check of parameter values). *See also:* **Logprob**, **Router Contract v2**.

**Logprob** — The log-probability a model assigns to a generated token, exposed via the **OpenAI-compatible endpoint**. Aide reads logprobs to derive routing confidence (see **Logprob-Derived Routing Confidence**) and does not rely on any self-reported confidence field. *See also:* **Confidence Gate**, **GBNF Grammar**.

**Sentinel Token** — A fixed, exact-match marker string the local LLM is system-prompted to emit under a defined condition, which Aide detects deterministically. The v1 sentinel is **`⟨UNSURE⟩`** `(Locked)`: the system prompt prefixes any low-confidence answer with it, and an exact string match triggers the uncertainty flow (**Offload** offer/auto if a BYOK key exists; otherwise the **teach-BYOK** message). *Not to be confused with:* a **Logprob** threshold (a numeric signal); the sentinel is a literal string contract. *See also:* **Honesty-over-Hallucination**, **Escalation / Offload**.

---

## 5. Routing & Confidence

**Router** — The LLM-driven component that turns a Command-Mode utterance (plus **Session Context**) into a structured routing decision. It **always runs locally** `(Locked)` and is constrained by a **GBNF Grammar** generated from the **Skill Registry**. Its output is the boundary between Aide's probabilistic half and its deterministic half. *Not to be confused with:* **Dispatch** (the deterministic execution that *consumes* the router's output). *See also:* **Router Contract v2**, **Intent**, **Continuation Detection**.

**Router Contract v2** — The authoritative routing output schema `(Locked; deliberately AMENDS the PRD's §6 contract)`. The Router emits exactly:

```json
{ "intent": "<short natural-language restatement>",
  "skill_id": "<registered skill id | null>",
  "parameters": { } }
```

Crucially, **there is NO `confidence` field** — confidence is measured externally from **Logprobs**, not self-reported by the model. Safety and gating are handled by the **Confidence Gate** stack (below), not by a model-emitted number. *Not to be confused with:* the PRD §6 v1 contract, which included a `confidence` field; v2 supersedes it. *See also:* **Logprob-Derived Routing Confidence**, **Schema Validation**, **GBNF Grammar**.

**Intent** — The `intent` field of **Router Contract v2**: a short natural-language restatement of what the user asked for (e.g., "open the Safari browser"). It is a human-legible label used in **Confirm-Back** copy and logs; it is **not** the executable identifier. *Not to be confused with:* **skill_id** (the machine identifier that selects a **Skill**). *See also:* **Skill Registry**.

**skill_id** — The `skill_id` field of **Router Contract v2**: the registered identifier of the **Skill** to invoke, or `null` when no skill matches. The token(s) that select `skill_id` are exactly where **Logprob-Derived Routing Confidence** is measured. *See also:* **Dispatch**, **Skill Registry**.

**Dispatch** — The deterministic step that, after all **Confidence Gate** checks pass, invokes the selected **Skill** with validated **parameters**. Dispatch is code, not the LLM; the LLM's involvement ends at the router boundary. *Not to be confused with:* **Routing** (choosing what to dispatch). *See also:* **Risk Tier**, **Schema Validation**.

**Confidence Gate** — The composite, deterministic gate that must pass before a routed intent is dispatched (or is escalated to **Confirm-Back**). It is *not* a single number; it is the ordered conjunction of: (1) the **Whisper Segment-Probability Pre-Gate**, (2) **Schema Validation** as a **hard rejection**, (3) **Logprob-Derived Routing Confidence** against calibrated thresholds, and (4) the skill's **Risk Tier** policy. *Not to be confused with:* the removed `confidence` field. *See also:* **Router Contract v2**, **Risk Tier**.

**Prompt-back** — The disambiguation response issued when the Router could **not** resolve a safe action: `skill_id: null` (nothing matched), a **Schema Validation** hard rejection, or a below-floor **Whisper Segment-Probability Pre-Gate** / routing logprob. Aide asks the user to clarify or repeat ("Did you mean…?" / "Did you say…?") and executes **nothing**. *Not to be confused with:* **Confirm-Back** — where an action *was* resolved but requires explicit confirmation because it is risky, marginal, or `always_confirm`. *See also:* **Confidence Gate**, **Router Contract v2**.

**Whisper Segment-Probability Pre-Gate** — The **first** safety gate `(Locked)`: it inspects Whisper's per-segment average token probabilities and gates out utterances the STT model itself transcribed with low confidence, *before* the text ever reaches the Router. Poor transcription is caught as poor transcription, not misrouted. *See also:* **Confidence Gate**, **Logprob-Derived Routing Confidence**.

**Logprob-Derived Routing Confidence** — Aide's routing-confidence signal `(Locked)`: a value computed from the LLM's **Logprobs** measured **at the `skill_id`-selecting tokens**, accounting for the fact that the **GBNF Grammar** renormalizes logprobs over grammar-legal tokens. Thresholds are **empirically calibrated over ~1 week** via the day-one **Calibration-Logging Harness**; until calibrated, **loose provisional thresholds** apply. *Not to be confused with:* a model-emitted `confidence` field (does not exist in v2). *See also:* **Calibration-Logging Harness**, **Confidence Gate**.

**Calibration-Logging Harness** — A day-one instrumentation harness that logs routing logprobs and outcomes locally so **Logprob-Derived Routing Confidence** thresholds can be empirically tuned over ~1 week `(Locked)`. It ships from day one precisely so the thresholds are data-driven, not guessed. *See also:* **Logprob-Derived Routing Confidence**, **Zero Telemetry** (the harness is strictly local).

**Schema Validation** — The deterministic validation of the router's `parameters` object against the target skill's **Manifest** parameter JSON-schema. In v2 a validation failure is a **HARD rejection** `(Locked)` — the intent is refused/prompted-back, *not* silently downgraded. *Not to be confused with:* **GBNF Grammar** constraint (which shapes generation) or **Logprob** confidence (a probabilistic signal). *See also:* **Manifest**, **Confidence Gate**.

**Continuation Detection** — See §10. The router's automatic classification of each utterance as a fresh command vs. a follow-up, using **Session Context**. Placed here because it is a routing responsibility. *See also:* **Session Context**, **New Topic**.

---

## 6. Safety

**Two-Layer Guard** — The locked, maximum-strictness protection against dangerous commands `(Locked)`. **Layer 1** is the deterministic **Dangerous-Command Scanner** (Swift, pattern-based, non-LLM, un-prompt-injectable). **Layer 2** is the **escalated confirmation UI** (**Confirm-Back**) that highlights flagged lines with plain-language risk explanations and demands a distinct, destructive-styled confirmation. LLM self-censoring is explicitly **not sufficient** on its own. *See also:* **Dangerous-Command Scanner**, **Confirm-Back**, **Hard-Block**.

**Dangerous-Command Scanner** — The Layer-1 deterministic scanner `(Locked)`: Swift, in-process, pattern-based, performing **recursive descent into pipes, `$()`, backticks, and `sh -c`** so obfuscated payloads are still analyzed. It **analyzes command strings as data** (never executes them to inspect them) and runs on every generated script before display, before *every* execution (so hand-edits re-trigger it), and on any dictated/typed one-off command destined for a terminal. It classifies matches into **Hard-Block** vs. **Confirm** tiers. *Not to be confused with:* the LLM's own refusal behavior (Layer 0, insufficient alone). *See also:* **Hard-Block**, **Confirm-Back**, **Scanner Scope**.

**Scanner Scope** — The defined surface the **Dangerous-Command Scanner** covers `(Locked)`: (a) **executable channels selected by routed intent** — i.e., commands that will actually run — **not** prose Q&A; and (b) **destination-aware** coverage of **Dictation Mode** text whose target is a terminal emulator (matched by a **bundle-ID allowlist**). Terminal-bound dictation of a dangerous command yields a **Confirm-Back with override**; **Hard-Block-no-override** is reserved for **Aide-generated automations**. *See also:* **Dictation Mode**, **Bundle-ID Allowlist**.

**Hard-Block** — The strictest scanner verdict: the command is **refused with no confirmation path and no override** `(Locked)`. `sudo`/any privilege escalation is the canonical hard-block — a voice-triggerable path to root must not exist. Hard-Block-no-override applies to **Aide-generated automations**; user-typed terminal dictation of the same pattern instead gets a **Confirm-Back with override** (see **Scanner Scope**). *Not to be confused with:* **Confirm-Back** (which *can* be overridden by explicit user confirmation). *See also:* **Two-Layer Guard**, **Risk Tier**.

**Confirm-Back** — The Layer-2 escalated confirmation interaction: flagged content (or a marginal-confidence route, or an `always_confirm` skill) is presented to the user with a plain-language risk/summary and requires an **explicit, distinct confirmation** — visually different from the ordinary approve action (e.g., a destructive-styled button or typed confirmation). *Not to be confused with:* a normal "OK"; Confirm-Back is deliberately higher-friction. *Not to be confused with:* **Hard-Block** (no confirmation exists). *See also:* **Risk Tier**, **Overlay**.

**Risk Tier** — A **per-Manifest** safety classification that governs how a passing route is executed `(Locked)`. *Not to be confused with:* **Tier** (RAM-based model selection). The three values:

- **`low`** — Execute immediately when all **Confidence Gate** checks pass. No confirmation.
- **`confirm`** — **Silent** (auto-execute) when **Logprob-Derived Routing Confidence** is high; **Confirm-Back** when the route is marginal.
- **`always_confirm`** — **Always Confirm-Back**, regardless of confidence, because the action is destructive/irreversible.

*See also:* **Manifest**, **Confidence Gate**, **Confirm-Back**.

**Blocklist** — The (non-exhaustive, aggressively extended) set of patterns the **Dangerous-Command Scanner** matches: `sudo`/privilege escalation (Hard-Block), destructive `rm`/`srm`/`shred`, piped remote execution (`curl … | sh`), `dd` to devices / `diskutil erase*` / `mkfs`, `chmod -R 777` and ownership changes on system paths, writes/deletes outside `$HOME` or in system-critical `~/Library` areas, `kill -9 -1` / killing system processes, `launchctl` changes to Aide's own or system jobs, shell-profile edits / `crontab -r`, `nvram`/`csrutil`/`spctl`/keychain dumps, fork bombs, and obfuscation (base64-decode-then-exec, `eval` of constructed strings). Default posture is **strict**: false positives acceptable, false negatives not. *See also:* **Dangerous-Command Scanner**, **Hard-Block**.

**Bundle-ID Allowlist** — The list of application bundle identifiers (terminal emulators) that make **Dictation Mode** insertion *destination-aware*, so dictated commands into those apps are scanned `(Locked, per Scanner Scope)`. *See also:* **Scanner Scope**, **Text Insertion**.

---

## 7. Skills, Automations & Scheduling

**Skill** — A single registered capability = an **implementation** (native Swift function OR a **Frozen Script**) plus a **Manifest** (id, description, parameter JSON-schema, declared permissions, optional schedule, enabled flag, failure counter, **Risk Tier**). Skills are the *only* things the **Router** can dispatch to. *Not to be confused with:* **General Knowledge Q&A** (a first-class built-in *capability*, not a registered skill). *See also:* **Built-in Skill**, **User Script-Automation**, **Skill Registry**.

**Built-in Skill** — A **Swift-backed** Skill shipped with Aide `(Locked)`. The v1 set includes: open/quit application, set timer/reminder (local notification), media control, take screenshot (feeds **Screen Q&A**), recurring reminders, "correct that: X should be Y" (feeds the **Personalization Dictionary**), and utility skills: weather (**Open-Meteo**), time/date & timezones, calculations/unit & currency conversion (**Frankfurter** for rates), and calendar-read (**EventKit**). Simple recurring things compile to **parameterized declarative actions** run by Aide's own scheduler — **never** LLM-generated shell scripts. *See also:* **Manifest**, **Local Notification**, **Declarative Action**.

**Declarative Action** — A parameterized, deterministic action (e.g., a reminder or app-launch-at-time) that Aide's own scheduler executes, produced by the LLM extracting *only* intent + parameters `(Locked)`. It is the safe alternative to script generation for the common-80% recurring cases. *Not to be confused with:* a **User Script-Automation** (arbitrary shell logic). *See also:* **launchd Agent**.

**User Script-Automation** — A user-created automation for arbitrary logic. Flow: user describes intent → LLM (**cloud-preferred** if a BYOK key exists) generates a **shell script + Manifest** → the **full script is shown before first registration** → on approval it is **Frozen** → registered with **launchd**. Its Manifest is the **same JSON schema** as built-ins (`id`, `description`, param schema, permissions, optional schedule, `enabled`, failure counter, **Risk Tier**), but the implementation is a script file rather than Swift `(Locked)`. *See also:* **Frozen Script**, **Failure Counter / Auto-Disable**, **Dangerous-Command Scanner**.

**Manifest** — The single JSON schema describing every Skill — built-in and user automation alike `(Locked)`. Fields (minimum): `id`, `description` (used verbatim in the router prompt), `parameters` JSON-schema, declared `permissions` (network? file-write paths?), optional `schedule`, `enabled` flag, `failure_counter` state, and **Risk Tier**. The **Router** prompt and **GBNF Grammar** are generated from the collection of manifests in the **Skill Registry**. *Not to be confused with:* an app-level entitlements plist. *See also:* **Skill Registry**, **Schema Validation**, **Risk Tier**.

**Skill Registry** — The single authoritative collection of all registered **Manifests** (built-in + user). It is the source from which the router prompt and **GBNF Grammar** are generated, and against which **Schema Validation** and **Dispatch** operate `(Locked: one registry, one manifest format, one scheduler)`. *See also:* **Router**, **Manifest**.

**launchd Agent** — A macOS per-user launchd job (a "user agent") that runs a scheduled **User Script-Automation** or **Declarative Action** per its Manifest schedule `(Locked)`. launchd handles sleep/wake schedule catch-up. A launchd user agent **never needs root** — which is why `sudo` is a **Hard-Block**. *Not to be confused with:* a system-level launchd *daemon* (never used). *See also:* **launchd**, **Frozen Script**.

**Frozen Script** — A generated shell script that, once approved, is **stored as a user-owned, user-editable file and never regenerated per run** `(Locked)`. Freezing makes execution deterministic. Because a user may hand-edit a frozen script, the **Dangerous-Command Scanner** re-runs before *every* execution. *Not to be confused with:* a per-run LLM generation (explicitly prohibited). *See also:* **User Script-Automation**, **Two-Layer Guard**.

**Failure Counter / Auto-Disable** — The per-Manifest guardrail state that counts **consecutive** execution failures and **auto-disables** the skill after N consecutive failures, with a user notification — so a broken automation never silent-fails forever `(Locked)`. Execution also enforces a per-run timeout and logs stdout/stderr locally. *See also:* **Manifest**, **launchd Agent**.

**Local Notification** — A macOS user notification Aide posts for timers/reminders, auto-disable alerts, and other surfaced states. All failures and important state changes surface as human-readable notifications, never silently. *See also:* **Built-in Skill**, **Failure Counter / Auto-Disable**.

**General Knowledge Q&A** — A **first-class built-in capability (not a user-managed registry Skill)**: the Router recognizes general questions ("who is X," "explain OAuth") and the **local LLM answers directly**. Mechanically it *is* a **reserved built-in router target** (`general_qa`) — a fixed GBNF alternative the Router emits deterministically, distinct from `skill_id: null` (which means only "nothing matched → prompt-back"); the Dispatcher special-cases it to the KnowledgeQA capability. Subject to the **Honesty-over-Hallucination** protocol and the **`⟨UNSURE⟩`** uncertainty flow. *Not to be confused with:* **Screen Q&A** (which answers about on-screen content — the reserved target `screen_qa`) or a web search (out of scope). *See also:* **Sentinel Token**, **Escalation / Offload**, **Prompt-back**.

**Honesty-over-Hallucination** — The locked protocol requiring the local LLM to *prefer admitting uncertainty over guessing*, especially for time-sensitive/post-cutoff and long-tail questions `(Locked)`. Enforced via aggressive system-prompt instruction that prefixes low-confidence answers with the **`⟨UNSURE⟩`** **Sentinel Token**. Acknowledged limitation: this reduces but cannot eliminate hallucination. *See also:* **Sentinel Token**, **General Knowledge Q&A**.

---

## 8. Privacy, Data & Cloud

**Local-First** — The load-bearing privacy invariant: all STT, OCR, routing, dictation cleanup, and screen Q&A run **locally**; pulling the network cable leaves everything working except explicit cloud escalation `(Locked)`. "Local unless I say otherwise" is the core trust promise. *Not to be confused with:* "local-only" — deliberate, user-visible **Escalation** to cloud exists. *See also:* **Zero Telemetry**, **Local/Cloud Indicator**.

**BYOK (Bring Your Own Key)** — The model whereby the user supplies their own cloud API key (base URL + key + model name) to enable cloud **Escalation**. Aide ships with no bundled cloud key; without BYOK, cloud paths are unavailable and Aide degrades gracefully with clear messaging. The same **OpenAI-compatible** client handles local and BYOK-cloud traffic. *See also:* **Escalation / Offload**, **OpenAI-compatible endpoint**.

**Escalation / Offload** — The **explicit, user-visible** act of sending a request to a **BYOK** cloud model. Two defined triggers: (1) **script/automation generation** escalates to cloud *by default if a key is configured* (small local models write buggy scripts), falling back to local with a visible "results may be rougher" caveat if no key; (2) the **`⟨UNSURE⟩`** uncertainty flow offers one-tap/one-phrase **Offload** (or auto-offloads if enabled). **No automatic "too hard for local" detection exists** — wrong guesses would silently ship user data, which is prohibited. Screenshots/audio **never** escalate implicitly. *Not to be confused with:* automatic fallback (prohibited). *See also:* **Local/Cloud Indicator**, **BYOK**.

**Local/Cloud Indicator** — The always-visible UI signal (in **Overlay**/**Menubar App**) that unambiguously shows whether the current request is running **local** or is **about to leave the machine** for the cloud `(Locked)`. Making "local unless I say otherwise" *legible* — not merely true — is a hard requirement. *Not to be confused with:* the **Listening State** (mic/processing status). *See also:* **Escalation / Offload**, **Local-First**.

**Personalization Dictionary** — The single, bounded source of truth for user-specific vocabulary corrections; **no model training anywhere** `(Locked)`. v1 is **explicit-only** — populated via the "correct that: X should be Y" command. **Entry shape:** correct term + known mishearings + occurrence counter + last-used timestamp. It is a **bounded, MRU-evicted** store. Correct **spellings** feed the **Whisper Bias Prompt** (respecting the ~224-token cap); mishearing→correct **pairs** feed the dictation **Cleanup Prompt**. Raw before/after pairs are discarded after extraction. *Not to be confused with:* long-term storage of transcripts (which are separate history). *See also:* **Whisper Bias Prompt**, **Cleanup Pass**, **MRU**.

**Cleanup Pass** — The **single, tone-aware** local-LLM rewrite applied to a Dictation-Mode transcript before insertion `(Locked default: one pass)`. It applies the active **Tone Preset**, consumes mishearing→correct pairs from the **Personalization Dictionary** via the **Cleanup Prompt**, and produces the final inserted text. *Not to be confused with:* the **Router** (Command Mode) — dictation never routes. *See also:* **Tone Preset**, **Dictation Mode**.

**Cleanup Prompt** — The LLM prompt used by the **Cleanup Pass**, into which mishearing→correct pairs from the **Personalization Dictionary** are injected. Bounded so it stays small forever. *Not to be confused with:* the **Whisper Bias Prompt** (STT-time, spellings only). *See also:* **Cleanup Pass**.

**Tone Preset** — The selectable rewrite style applied during the **Cleanup Pass** `(Locked v1 set)`: **As-is** (fix grammar/remove filler, keep the user's voice — **default**), **Professional**, **Casual**, **Concise**. Custom user-defined tones are post-v1. Quick-switchable (e.g., a voice prefix like "professional tone: …"). *See also:* **Dictation Mode**, **Cleanup Pass**.

**Wipe History** — The one-click settings action that deletes **transcripts, command log, and script-execution logs** `(Locked)` — and *not* settings, scripts, or the **Personalization Dictionary** unless separately chosen. *See also:* **Application Support**, **Zero Telemetry**.

**Zero Telemetry** — The absolute invariant `(Locked)`: no analytics, no third-party crash reporting, nothing phones home. All logs are **local, plain, human-readable** files. The **Calibration-Logging Harness** is fully local and does not violate this. *See also:* **Local-First**, **Wipe History**.

**Open-Meteo** — The free, keyless weather API used by the weather **Built-in Skill** `(Locked default)`. It is one of exactly two disclosed implicit network calls (the other is **Frankfurter**), disclosed **once** at onboarding, then not re-nagged per request. *See also:* **Frankfurter**, **Local/Cloud Indicator**.

**Frankfurter** — The free, keyless currency-rate API used for currency conversion `(Locked default)`. The second of the two disclosed keyless utility calls. *See also:* **Open-Meteo**.

---

## 9. Screen Understanding

**Screen Q&A** — The **Command-Mode** capability where the user asks a question about what is on screen: Aide captures the screen, OCRs it, and feeds the extracted text + question to the **local text LLM** for an answer shown in the **Overlay**. **No VLM** is used in v1. If OCR yields nothing useful (pure image content), Aide says so honestly rather than hallucinating. *Not to be confused with:* **General Knowledge Q&A** (about the world, not the screen). *See also:* **screencapture**, **OCR / Apple Vision**.

**screencapture** — The macOS mechanism (the `screencapture` utility / equivalent API) Aide uses to capture the screen for **Screen Q&A** `(Locked)`. Captured images are processed **in memory / temp** and **not retained beyond the session** unless the user explicitly saves one, and are **never uploaded implicitly**. Requires the **Screen Recording** permission. *See also:* **OCR / Apple Vision**, **Screen Recording permission**.

**OCR / Apple Vision** — The **Apple Vision framework** text-recognition step that converts a screen capture into text **at native resolution**, preserving rough spatial layout via **Bounding Boxes** `(Locked)`. This is the *only* screen-understanding path in v1 — **no VLM**. *Not to be confused with:* a vision-language model (out of scope). *See also:* **Bounding Box**, **Screen Q&A**.

**Bounding Box** — The rectangular coordinates Vision returns for each recognized text region, used to preserve rough on-screen layout when serializing OCR output for the LLM. This layout hint improves answer quality for spatially structured screens. *See also:* **OCR / Apple Vision**.

---

## 10. Session & Context

**Session Context** — The rolling, **bounded, fully-local** conversational memory kept in the LLM context for a session: the last ~6–8 exchanges plus the **most recent screen OCR capture** `(Locked)`. Retained screen content obeys the privacy invariant (never leaves the machine implicitly). It enables follow-ups ("what does this error mean" → "how do I fix it"). *Not to be confused with:* the **Personalization Dictionary** (persistent vocabulary, not conversational). *See also:* **Continuation Detection**, **Idle Timeout**, **Model Residency**.

**Continuation Detection** — The **automatic** classification, performed by the **Router** on *every* utterance (which sees **Session Context**), of fresh-command vs. follow-up — **no user action required** `(Locked)`. "**New Topic**" is an optional override, not the mechanism. A follow-up wrongly matched to a skill at low confidence is caught by the standard **Confidence Gate** prompt-back. *See also:* **New Topic**, **Router**.

**New Topic** — The optional explicit user command that clears **Session Context** immediately, overriding **Continuation Detection**. It is a convenience override, not the primary mechanism. *See also:* **Idle Timeout**.

**Idle Timeout** — The inactivity duration after which **Session Context** expires; default **8 minutes** `(Locked default)`. On the **8GB tier** the same idle activity also governs LLM unload (**Model Residency**); session activity resets the unload timer. *Not to be confused with:* per-run *script* timeouts (execution guardrails). *See also:* **Session Context**, **Model Residency**, **TTL**.

---

## 11. Platform, Permissions & Distribution

**Text Insertion** — Placing dictated/cleaned text at the current cursor position. Strategy is **AX-first, clipboard-paste fallback** `(Locked)`: attempt insertion via the **Accessibility API** (**AXUIElement**); if the target app rejects AX insertion (common in Electron), fall back to a clipboard paste that **saves and restores** the prior clipboard contents. Governed by a **per-app allow/deny map**. *See also:* **AX-first**, **Accessibility / AX**, **Bundle-ID Allowlist**.

**AX-first** — The Text Insertion ordering: try **AXUIElement** insertion first, only then the clipboard-paste fallback `(Locked)`. Non-negotiable that the fallback exists **from day one**. *See also:* **Text Insertion**.

**Accessibility / AX** — The macOS **Accessibility** API and its **TCC** permission. Aide requires it for two things: installing the **CGEventTap** (hotkeys) and performing **AXUIElement**-based **Text Insertion**. Denying it disables hotkeys and AX insertion (graceful degradation). *See also:* **AXUIElement**, **CGEventTap**, **TCC**.

**AXUIElement** — The Accessibility API object representing a UI element; Aide reads/sets the focused element's value to insert text (the AX path of **Text Insertion**). *See also:* **Accessibility / AX**, **AX-first**.

**TCC (Transparency, Consent & Control)** — Apple's per-app permission subsystem gating Microphone, Accessibility, Screen Recording, and Calendar access. Aide's **Onboarding** requests each **one at a time with a plain-language "why,"** deep-links to the exact System Settings pane, and detects the grant to auto-advance. *See also:* **Microphone permission**, **Screen Recording permission**, **Accessibility / AX**, **EventKit / Calendar**.

**Microphone permission** — The **TCC** grant required for STT audio capture. Denial disables all voice input. *See also:* **TCC**, **STT**.

**Screen Recording permission** — The **TCC** grant required for **screencapture** used by **Screen Q&A**. Denial disables Screen Q&A only. *See also:* **screencapture**, **Screen Q&A**.

**EventKit / Calendar** — The **EventKit** framework and its **Calendar TCC** permission, used by the calendar-read **Built-in Skill** ("what's on my schedule today"). This permission is **optional/skippable** during onboarding; denial disables only calendar queries. *See also:* **Built-in Skill**, **TCC**.

**Onboarding** — The required first-run flow: welcome + privacy promise → RAM detection & **Tier** confirm/override → resumable **model downloads** with progress/sizes → **TCC** permission walkthrough (one at a time, each with a "why," deep-linked) → hotkey setup → guided first success. It also **discloses once** the two keyless utility calls (**Open-Meteo**, **Frankfurter**). Any denied permission disables only dependent features, with a persistent fix-it hint. *See also:* **Graceful Degradation**, **Tier**.

**Graceful Degradation** — The principle that any denied permission or missing capability disables **only** the dependent feature — never mysterious breakage — with a persistent, actionable fix-it hint in settings `(Locked)`. *See also:* **Onboarding**, **TCC**.

**Entitlements** — The app capability declarations (e.g., microphone, Apple Events, app sandbox posture) configured **from day one** so that signing/notarization is a settings flip, not a refactor `(Locked)`. *See also:* **Hardened Runtime**, **Notarization**.

**Hardened Runtime** — The macOS runtime-protection option enabled on the app from day one (a prerequisite for **Notarization**) `(Locked)`. *See also:* **Entitlements**, **Notarization**, **Code Signing**.

**Code Signing** — Signing builds with the enrolled **Apple Developer Program** identity. Per Locked Decisions, **dev builds are signed day one** (unsigned local builds are merely tolerated, not the target). *See also:* **Notarization**, **Hardened Runtime**.

**Notarization** — Apple's automated malware-scan-and-staple process applied to the signed app before distribution. With entitlements + hardened runtime configured day one, enabling it is a settings flip. *See also:* **DMG**, **Hardened Runtime**.

**DMG** — The disk-image distribution artifact `(Locked)`. Aide is delivered by direct **DMG** download — **not** the App Store. *See also:* **Notarization**, **Model delivery**.

**Model delivery** — The mechanism for obtaining model weights: downloaded from **official Hugging Face repos**, each **pinned to a commit SHA + SHA-256**, **resumable**, and shown with progress/sizes at first launch `(Locked)`. Models are **not bundled** in the `.app`. *See also:* **Application Support**, **Tier**, **GGUF**.

**Application Support** — The on-disk home for all Aide data: `~/Library/Application Support/Aide/` holds settings, the **Personalization Dictionary**, the **Skill Registry**, **Frozen Scripts**, transcripts/command history, script-execution logs, and downloaded models `(Locked; models must be user-discoverable — Caches is an allowed alternative location for weights only)`. *See also:* **Wipe History**, **Model delivery**.

**launchd** — The macOS service manager Aide uses to schedule automations as **launchd Agents** (per-user), including sleep/wake schedule catch-up. *Not to be confused with:* `launchctl` operations, which the **Dangerous-Command Scanner** guards. *See also:* **launchd Agent**, **Declarative Action**.

**Single Instance** — The enforced guarantee that only one Aide process runs at a time `(Locked NFR)`, preventing duplicate hotkey taps and sidecar/port conflicts. *See also:* **Dynamic Localhost Port**, **Menubar App**.

**Resilience** — The NFR posture that no subsystem failure takes the app down: sidecar crashes auto-restart with **Backoff Restart**, and all failures surface human-readable states, never silently `(Locked NFR)`. *See also:* **Backoff Restart**, **Health Check**.

---

## 12. Acronym Index

| Acronym | Expansion | See |
|---|---|---|
| **API** | Application Programming Interface | **OpenAI-compatible endpoint** |
| **AX** | Accessibility (macOS Accessibility API) | **Accessibility / AX**, **AXUIElement** |
| **BYOK** | Bring Your Own Key | **BYOK**, **Escalation / Offload** |
| **CG** | Core Graphics (as in **CGEventTap**) | **CGEventTap** |
| **DDD** | Domain-Driven Design (methodology behind this glossary) | §1 |
| **DMG** | (Apple) Disk iMaGe distribution file | **DMG** |
| **GBNF** | GGML Backus–Naur Form (grammar) | **GBNF Grammar** |
| **GGUF** | GGML Universal (model weight file) Format | **GGUF** |
| **HF** | Hugging Face (model source) | **Model delivery** |
| **HLD** | High-Level Design | [`04-hld.md`](04-hld.md) |
| **HTTP** | HyperText Transfer Protocol | **OpenAI-compatible endpoint** |
| **JSON** | JavaScript Object Notation | **Manifest**, **Router Contract v2** |
| **LLD** | Low-Level Design | [`05-lld.md`](05-lld.md) |
| **LLM** | Large Language Model | **LLM**, **Qwen3** |
| **MRU** | Most-Recently-Used (eviction) | **Personalization Dictionary** |
| **NFR** | Non-Functional Requirement | **Resilience**, **Single Instance** |
| **OCR** | Optical Character Recognition | **OCR / Apple Vision** |
| **PRD** | Product Requirements Document | source: `aide-prd.md` |
| **PTT** | Push-to-Talk | **Push-to-Talk** |
| **RAM** | Random-Access Memory (drives **Tier**) | **Tier** |
| **SHA** | Secure Hash Algorithm (commit SHA / SHA-256 pinning) | **Model delivery** |
| **STT** | Speech-to-Text | **STT**, **whisper.cpp** |
| **SwiftPM** | Swift Package Manager | **whisper.cpp**, §3 arch |
| **TCC** | Transparency, Consent & Control (macOS permissions) | **TCC** |
| **TTL** | Time-To-Live (as applied to **Idle Timeout** / **Session Context**) | **Idle Timeout** |
| **UI / UX** | User Interface / User Experience | **Overlay**, **Onboarding** |
| **VLM** | Vision-Language Model (**out of scope** for v1) | **Screen Q&A** |

---

*End of glossary. Terms defined here are authoritative for [`01-problem-to-solve.md`](01-problem-to-solve.md), [`03-architecture.md`](03-architecture.md), [`04-hld.md`](04-hld.md), [`05-lld.md`](05-lld.md), and [`06-walkthrough.md`](06-walkthrough.md).*
