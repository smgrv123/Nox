# PRD — P2b · LLM Runtime

> Second of the two verticals **P2 · Inference Core** (see [`docs/07-implementation-pillars.md`](../docs/07-implementation-pillars.md)) is split into:
> **P2a · Speech-to-Text** (shipped) and **P2b · LLM Runtime** (this doc).
> Grounded in [`docs/04-hld.md`](../docs/04-hld.md) §4 and [`docs/05-lld.md`](../docs/05-lld.md) §3.3–3.4, §5.1, §5.4, plus §4.3 (Model Residency, LLM half).
> Status: draft spec · not yet planned.

## Why P2 is split (recap from P2a)

P2a shipped **audio → text**, in-process, no subprocess, no HTTP, local-only. P2b is the other half: **text → text**, out-of-process (`llama-server` Sidecar) + the single OpenAI-compatible client. They share only the **model-provisioning** mechanism (resumable, SHA-256-pinned download + on-disk verify) and RAM/Tier detection — P2a built those deep modules once; P2b reuses them.

## Problem Statement

Even with P2a shipped, Aide still can't *do* anything with what it hears. Command routing (P4), dictation cleanup (P5), and Q&A (P6) are all "send a prompt, get text back" — and today there is no LLM running anywhere on the machine, no way to get one there safely, and no client to talk to it. Every capability above this layer is blocked on a component that doesn't exist yet.

It also has to be built defensively from day one: the architecture doc names `llama.cpp` as *the* component "most likely to hang or crash under memory pressure" — exactly why it's a separate Sidecar process rather than in-process like Whisper. If that isolation, health-checking, and restart logic isn't solid, a bad inference run takes the whole app down with it instead of just this one runtime recovering on its own. And because the LLM weights are multi-GB, "get the model onto the machine" has to be as resumable and tamper-evident as it was for Whisper — a half-downloaded or corrupted Qwen GGUF is worse than none.

## Solution

A local, out-of-process **LLM runtime vertical**:

- **`llama-server` runs as the sole Sidecar process** — bundled inside the app, version + checksum-pinned (same posture as the whisper.cpp xcframework), spawned on a **dynamic localhost port** (never fixed, never non-loopback). A **health-check** poll gates "ready"; on crash or a failed health check, the Sidecar **restarts with bounded exponential backoff** (`1s, 2s, 4s, 8s, capped 30s`, reset after 60s healthy) — the app never goes down with it, and repeated failure surfaces a legible state rather than hanging silently.
- **One OpenAI-compatible client (`InferenceClient`)** for every LLM call, local or cloud — the target (Sidecar port vs. a BYOK base URL) is the *only* difference, which is what makes the eventual Local/Cloud Indicator (P6) a single auditable choke point. It supports optional **GBNF grammar** constraint (passthrough only — grammar *generation* from the Skill Registry is P4's job) and optional **logprobs** (for the Router's confidence signal, also P4), plus **streaming** for answer surfaces (P6). The cloud target is built into the abstraction now (cheap, avoids rework) but is **not exercised** in this PRD — no settings UI, no API key handling, no real network call to a cloud endpoint; that consent-gated wiring is P6.
- **Model provisioning reuses P2a's `ModelProvisioning` module unchanged** — the same resumable, pinned-commit + SHA-256-verified download machinery that fetched Whisper now fetches the Tier-appropriate **Qwen3 GGUF** (Qwen3-8B Q4_K_M on 16GB, Qwen3-4B Q4_K_M on 8GB) into the same user-discoverable models directory.
- **Model Residency** is Tier-gated: on 16GB the LLM stays resident so follow-ups are instant; on 8GB it **unloads after an idle timeout** to reclaim RAM and **reloads on next use** with a brief visible loading state — Session Context (a P6 concept) is never dropped by an unload, and any activity resets the idle timer.

Proven two ways, mirroring P2a's bar: **headlessly**, an opt-in integration check spawns the real bundled `llama-server`, sends a fixed prompt, and asserts a sane completion with logprobs present; and **manually**, a minimal debug affordance (not a real feature — P4/P5/P6 don't exist yet to be the real consumer) lets a person trigger a real local completion and see it render, the same spirit as P2a's live Overlay demo.

Everything above the OS-bound edges (the process spawn, the HTTP call, the network GET) is a **pure, headlessly-tested deep module**: the tier→model mapping, the backoff schedule, and the idle-unload state machine. The effectful shells around them are thin and integration-/manually-verified, exactly as P2a treated `AudioCapture` and `ModelDownloader`.

## User Stories

### Real local completion (the vertical)
1. As a developer building P4/P5/P6, I want a running local LLM I can send a prompt to and get text back from, so that command routing, dictation cleanup, and Q&A have something to call.
2. As a user, I want that completion to run entirely **on my Mac** by default, so that nothing I say or ask leaves the machine unless I explicitly opt into cloud.
3. As a developer, I want the client to optionally request **logprobs**, so that the future Router (P4) can derive routing confidence from them.
4. As a developer, I want the client to optionally pass a **GBNF grammar**, so that the future Router (P4) can constrain decoding to valid skill JSON.
5. As a developer, I want the client to support **streaming** responses, so that future answer surfaces (P6) can render text as it arrives rather than waiting for the whole completion.

### Resilience of the Sidecar
6. As a user, I want the LLM runtime to be isolated in its own process, so that if it hangs or crashes under memory pressure it doesn't take Aide down with it.
7. As a user, I want a crashed or unresponsive Sidecar to **restart itself automatically**, so that a transient failure recovers without me having to relaunch the app.
8. As a user, I want repeated Sidecar failures to surface as a clear, human-readable state (not a silent hang or a crash), so that I know what's wrong and that Aide is still otherwise alive.
9. As a developer, I want the Sidecar to bind localhost-only on a dynamically chosen port, so that it can never collide with another process or be reached from outside the machine.

### Getting the LLM model onto the machine
10. As a first-time user, I want the LLM model to download automatically for my confirmed tier, so that I don't have to hunt for GGUF files myself.
11. As a user, I want that download to **resume** if it's interrupted, so that a multi-GB download doesn't restart from zero after a quit or dropped connection.
12. As a user, I want the downloaded model **verified against a known checksum**, so that a corrupted or tampered file is caught before it's ever loaded.
13. As a user, I want to see honest download progress and a clear, actionable error on failure, so that setup never looks frozen.
14. As a user, I want Aide to detect an already-present, verified model and skip re-downloading, so that later launches are instant.
15. As a user on a smaller machine, I want the **RAM-appropriate** Qwen variant, so that the LLM actually runs on my hardware.

### Model Residency & idle-unload
16. As a 16GB-tier user, I want the LLM to stay loaded between requests, so that follow-up interactions feel instant.
17. As an 8GB-tier user, I want the LLM to unload itself after a period of inactivity, so that it isn't holding RAM I need for other things when I'm not using Aide.
18. As an 8GB-tier user, I want the LLM to reload automatically (with a brief visible loading state) the next time I need it, so that unloading never feels like a dead end.

### Developer-facing (pillar consumers)
19. As a developer building P4/P5/P6, I want a stable `LLMClient` interface (`routeComplete` / `chat`) with a mock conformer, so that I can develop against it without the Sidecar running.
20. As a developer, I want the tier→model mapping, the backoff schedule, and the idle-unload timer to be **pure and unit-tested headlessly**, so that the risky process/network code is a thin, trustworthy shell.
21. As a developer, I want the `llama-server` binary **pinned by checksum**, so that builds stay reproducible and the native surface can't shift under me.
22. As a developer, I want P2b to reuse P2a's `ModelProvisioning` module unchanged, so that the two verticals don't carry two different download/verify implementations.

## Implementation Decisions

**Vertical boundary.** P2b owns Sidecar lifecycle + the OpenAI-compatible client + LLM-model provisioning + Model Residency. It does **not** own grammar *generation*, routing decisions, dictation cleanup, Q&A, script generation, or any real cloud call — those are P4/P5/P6/P7. The live demo is a minimal debug hook, not a real feature surface.

**Native binary posture (mirrors P2a's locked precedent):** `llama-server` ships as a **prebuilt, version + checksum-pinned executable**, bundled into the `.app` (not built from source). The upstream release, version/commit, and checksum are recorded in `docs/native-deps.md` alongside the existing whisper.cpp pin, following the same verification pattern (cross-checked hash, documented provenance).

**Out-of-process, dynamic port (locked decisions 3/5):** `llama-server` is a separate spawned process, never in-process — the deliberate fault-isolation tradeoff for the component most likely to hang/crash under memory pressure (unlike Whisper, kept in-process for the latency-critical STT hot path). Port is bound to `:0`, the OS-assigned port is read back and passed to the client; the process binds `127.0.0.1` only, is killed on app exit (no orphan), and its stdout/stderr are logged.

**Shared `Tier` concept (a P2a refactor, mechanical).** `Tier` (the `tier8GB`/`tier16GB` enum + RAM-boundary resolution + override) currently lives inside `SpeechToText.SttTierPolicy`. It moves into `ModelProvisioning` — the module both verticals already share — because HLD §4.3's tier table ties a Whisper model *and* a Qwen model to the same RAM row; keeping two independent copies of the boundary logic is a needless duplication risk. `SttTierPolicy` becomes a thin `Tier → Whisper ModelDescriptor` mapper against the shared type; its existing tests move with it unchanged in intent.

**Modules (deep, headlessly tested where possible):**

- **`ModelProvisioning`** (existing, extended) — the shared `Tier` type (moved from `SpeechToText`, see above) plus new production `ModelDescriptor` pins for the Qwen3-8B and Qwen3-4B Q4_K_M GGUF files (repo, pinned revision, filename, SHA-256, byte size), following the exact pinning/provenance pattern already used for the Whisper models.
- **`LLMRuntime`** (new SwiftPM module) — the pure heart of P2b, playing the role `SpeechToText` played for P2a:
  - **`LlmTierPolicy`** — pure map from `Tier` → the Qwen `ModelDescriptor` (mirrors `SttTierPolicy.whisperModel(for:)`).
  - **`LLMEndpoint`** — base URL, optional API key reference, model name, `isLocal` flag (drives the future Local/Cloud Indicator).
  - **`LLMClient` protocol** — `routeComplete(system:user:grammar:endpoint:) -> RouterCompletion` (grammar-constrained, with per-token logprobs) and `chat(system:messages:params:endpoint:stream:) -> ChatCompletionStream` (free-form, streaming). The seam P4/P5/P6 build against.
  - **`SidecarController` protocol** + **`SidecarState`** (`stopped` / `launching` / `ready(port:)` / `unhealthy(retryIn:)` / `failed(reason:)`) — the lifecycle seam (LLD §3.4/§5.1).
  - **Backoff schedule** — a pure function of (attempt count, time since last healthy) → next delay / give-up, implementing the `1,2,4,8..30s capped, reset after 60s healthy` rule, injectable-clock so it's deterministic to test.
  - **Idle-unload state machine** — a pure function of (Tier, time since last request) → resident/unload decision (LLD §5.4): 16GB never unloads; 8GB unloads after the idle threshold and signals reload-on-next-use. Consumed by the effectful `SidecarManager` shell, which owns the actual timer.
  - **`MockLLMClient`** — deterministic conformer (canned completions, injectable logprobs/streaming chunks) so P4/P5/P6 can develop against `LLMClient` without a live Sidecar, mirroring P2a's `MockSTTEngine`.
- **Effectful shells (integration-/manually-verified, not in the headless unit suite — the P1 `CGEventTap` / P2a `AudioCapture` precedent):**
  - **`InferenceClient`** — the concrete `LLMClient` conformer: a `URLSession`-based OpenAI-compatible HTTP client. Talks to the local Sidecar's dynamic port today; the cloud-target code path exists (same client, different `LLMEndpoint`) but is not exercised against a real cloud endpoint in this PRD.
  - **`SidecarManager`** — the concrete `SidecarController` conformer: spawns the bundled `llama-server` binary via `Process` on a `:0`-bound port, drives the health-check poll, applies the pure backoff and idle-unload state machines on real timers, writes `logs/sidecar.log`, and guarantees the child is killed on app exit.

**Model residency (LLM half of HLD §4.3).** Unlike Whisper (kept resident regardless of tier in P2a), the LLM's idle-unload is a first-class, Tier-gated behavior built in this PRD — it's explicitly named in the locked Model Residency state machine (LLD §5.4) and belongs with the Sidecar/tier work rather than bolted on by a later pillar.

**Storage.** Qwen model blobs + their `.download-state.json` live under the same user-discoverable models directory as the Whisper models, using the unchanged `ModelProvisioning`/`ModelDownloader` machinery (atomic state writes, resumable range requests) — no new storage code.

**No new logic dependencies.** The only new third-party artifact is the pinned `llama-server` binary (authorized this session, mirroring whisper.cpp's precedent). No new Swift package dependencies for the pure modules; `InferenceClient` uses `URLSession`/`Foundation` only.

## Testing Decisions

**Approach: TDD (red-green-refactor), tests-first**, for every deep module — same posture and prior art as P2a (`DangerousCommandScanner`, `SegmentPreGate`, `SttTierPolicy`).

**What makes a good test here:** drives the module through its **public interface** with injected inputs (a constructed RAM byte count, an injected clock + attempt count, a fabricated health-check result sequence) and asserts outputs/state transitions — never internal implementation details. No real process spawn, no real network, no real llama-server in the headless suite; time is injected so backoff and idle-unload tests are deterministic and fast.

**Modules under test (all deep modules):**
- **`ModelProvisioning`'s `Tier`** (moved from `SpeechToText`) — RAM boundary cases (≥16GB, 8GB, the boundary) and override-wins-both-ways, carrying forward `SttTierPolicyTests`' existing coverage unchanged in intent.
- **`LlmTierPolicy`** — Tier → correct Qwen `ModelDescriptor`.
- **Backoff schedule** — attempt sequence → correct delay sequence (`1,2,4,8,...,30s` cap); a healthy interval > 60s resets the attempt count; max-retries → give-up/`failed` transition.
- **Idle-unload state machine** — 8GB tier transitions to unload after the idle threshold elapses with no activity; any activity resets the timer; 16GB tier never transitions to unload regardless of idle time; an unloaded 8GB instance signals reload on the next request.
- **`SidecarState`/`SidecarController` seam** — state-transition correctness driven by an injected fake process/health-check source (mirrors how `STTVoiceSessionDriverTests` drove the P2a driver with an injected `MockSTTEngine` + fake capture, keeping the real process spawn out of the headless gate).

**Not unit-tested (verified by an integration check + manually, like P1's `CGEventTap` and P2a's `AudioCapture`/`ModelDownloader`):**
- **Headless integration check** (opt-in, not part of the fast unit gate): spawn the real bundled `llama-server` with a downloaded Tier model → send a fixed prompt via the real `InferenceClient` → assert a sane completion with populated logprobs, mirroring `WhisperSTTEngineTests`' "sample WAV → transcript" pattern for this vertical's "prompt → completion with logprobs" acceptance line from the pillar's "Done."
- **Live/manual:** confirm the Sidecar survives a killed child process (restarts within the backoff window); confirm a fresh machine downloads → verifies → serves a completion end-to-end; on an 8GB machine, confirm idle-unload actually happens and a follow-up reloads with a visible brief state; trigger the manual debug hook and confirm a real local completion renders.

## Out of Scope

- **Router Contract v2, GBNF grammar *generation*, Logprob-Derived Routing Confidence, dispatch, Skill Registry** — **P4**. P2b's client accepts an already-built grammar and requests logprobs; it does not generate or interpret either.
- **Dictation cleanup (tone pass), Text Insertion, Personalization Dictionary** — **P5**.
- **General-Knowledge Q&A, ⟨UNSURE⟩ flow, Screen Q&A, Session Context, real cloud escalation / BYOK settings UI / consent flow / Local-Cloud Indicator** — **P6**. The cloud-target *shape* exists in `LLMEndpoint`/`InferenceClient`; nothing in this PRD configures, authenticates, or calls a real cloud endpoint.
- **User Script-Automations, script generation, `launchd` registration** — **P7**.
- **Building `llama-server` from source** — a prebuilt, pinned binary only, mirroring the whisper.cpp precedent.
- **Final backoff/idle-unload threshold calibration** — the values in LLD §3.4/§5.4 (`1,2,4,8..30s`, the idle-timeout duration) are shipped as specified but treated as provisional/injectable, same posture as P2a's Pre-Gate thresholds.

## Further Notes

- **Independence via the seam:** P2b sits on `ModelProvisioning` (shared with P2a) and introduces the `LLMClient`/`SidecarController` seams that P4/P5/P6 will build against, but depends on **no** feature pillar itself. `MockLLMClient` is what lets those three pillars start development before this vertical's real Sidecar is even running.
- **Resilience framing:** the Sidecar's failure posture mirrors the Pre-Gate's safety posture from P2a — prefer a visible, recoverable degraded state over a silent hang or a full app crash. A Sidecar that fails to restart within its backoff budget must surface as legible, never silent.
- **"Done" (acceptance demo):** on the M2/16GB reference machine — confirm tier in onboarding → Qwen model downloads (resumable) + verifies → the Sidecar spawns and reaches `ready` → the headless integration check (fixed prompt → real completion + logprobs) is green → the manual debug hook renders a real local completion → killing the Sidecar process manually triggers an automatic restart within the backoff window → all deep-module unit suites are green via `swift test`.
- **Relevant NFRs (design toward):** a Sidecar crash never takes the app down; every failure (no model, corrupt model, Sidecar unreachable, max retries exceeded) surfaces a human-readable state; 16GB follow-ups feel instant; 8GB idle-unload never drops in-progress context.
- **Reference machine:** Apple M2 / 16GB, macOS 14+, Apple Silicon only.
- This PRD is the input to the P2b **phased plan** (`/prd-to-plan` → `plans/P2b-llm-runtime.md`), authored next.
