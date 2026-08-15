# Plan: P2b · LLM Runtime

> Source PRD: [`specs/P2b-llm-runtime.md`](../specs/P2b-llm-runtime.md) — second of the two verticals P2 · Inference Core is split into (P2a · Speech-to-Text shipped; P2b · LLM Runtime here).
> Grounded in `docs/04-hld.md` §4 and `docs/05-lld.md` §3.3–3.4, §5.1, §5.4, §4.3 (LLM half).
> Execution: `/execute-plan --tdd`, **one phase at a time**, each gated + paused for review before the next.

## Architectural decisions

Durable decisions that apply across all phases:

- **Native binary (locked, mirrors P2a's whisper.cpp precedent):** `llama-server` ships as a **prebuilt, version + checksum-pinned executable**, bundled into the `.app` and spawned via `Process` — never built from source, never in-process. The upstream release tag/commit + checksum are recorded in `docs/native-deps.md` alongside the existing whisper.cpp entry.
- **Out-of-process, dynamic port (locked):** the Sidecar binds `127.0.0.1` on a port chosen by binding `:0`, reading the assigned port back, then passing it explicitly to the client — never a fixed port, never `0.0.0.0`. Killed on app exit (no orphan); stdout/stderr logged to `logs/sidecar.log`.
- **New/extended SwiftPM modules:**
  - **`LLMRuntime`** (new, pure, headless) — `LlmTierPolicy`; `LLMEndpoint`; the `LLMClient` protocol (`routeComplete`, `chat`) + `MockLLMClient`; the `SidecarController` protocol + `SidecarState`; the pure backoff-schedule function; the pure idle-unload state machine.
  - **`ModelProvisioning`** (existing, extended) — `Tier` **moves here** from `SpeechToText` (shared RAM-boundary concept, both a Whisper and a Qwen model hang off the same tier row per HLD §4.3); new pinned `ModelDescriptor`s for Qwen3-8B-Q4_K_M / Qwen3-4B-Q4_K_M. `SttTierPolicy` becomes a thin `Tier → Whisper ModelDescriptor` mapper against the shared type; its existing tests move with it.
  - Both registered in `Package.swift` (+ test targets) and, where the app links them, `project.yml` → `just gen`.
- **Effectful shells (App/ layer, integration-/manually-verified — the P1 `CGEventTap` / P2a `AudioCapture` precedent, NOT in the headless unit gate):** `SidecarManager` (concrete `SidecarController`: real `Process` spawn, health polling, backoff/idle-unload timers), `InferenceClient` (concrete `LLMClient`: `URLSession`-based OpenAI-compatible HTTP client).
- **Key data shapes (durable):**
  - `LLMEndpoint { baseURL; apiKeyRef: KeychainRef?; model: String; isLocal: Bool }`.
  - `LLMClient.routeComplete(system:user:grammar:endpoint:) -> RouterCompletion { raw; decision; tokenLogprobs: [TokenLogprob] }`; `LLMClient.chat(system:messages:params:endpoint:stream:) -> ChatCompletionStream`.
  - `SidecarState`: `.stopped` / `.launching` / `.ready(port:)` / `.unhealthy(retryIn:)` / `.failed(reason:)` (LLD §3.4/§5.1).
  - `ModelDescriptor` (unchanged shape from P2a) gains two new production instances for the Qwen models.
- **Sidecar semantics (locked):** health-check gates `ready`; backoff schedule `1s, 2s, 4s, 8s, capped 30s`, reset after a healthy interval > 60s; max-retries → `.failed` (manual retry surfaced in Menubar). Grammar constraint and logprobs are **passthrough only** in P2b — generation/interpretation is P4.
- **Model Residency (LLD §5.4, locked):** 16GB tier stays resident indefinitely; 8GB tier unloads after an idle timeout and reloads on next request with a brief visible loading state. The idle-unload decision is a pure function of (Tier, time-since-last-request); the real timer lives in the effectful `SidecarManager`.
- **Local-first invariant:** the only new network egress in P2b is the one-time Qwen model download (reusing P2a's `ModelDownloader` unchanged) plus loopback-only Sidecar HTTP. The cloud-target code path exists in `LLMEndpoint`/`InferenceClient` but is **not exercised** against a real cloud endpoint anywhere in this plan — no settings UI, no key handling, no outbound cloud call (that's P6).
- **Testing posture:** TDD (red-green-refactor), tests-first, for every deep module, headless via `swift test` — same prior art as P2a (`DangerousCommandScanner`, `SegmentPreGate`, `SttTierPolicy`). Time is injected (backoff, idle-unload) so tests are deterministic. Process/network shells are excluded from the fast unit gate and verified by an opt-in integration check + manual test.
- **Per-phase gate (MUST, all phases):** `just check` green (format-check + SwiftLint + `swift build` + `swift test`) **and** `just app` builds **and** SwiftLint reports **0 warnings**; new/moved modules registered in `Package.swift`/`project.yml` and `just gen` run where the app links them. Phase is not "done" until these pass and the user has reviewed.

---

## Phase 1: Native Sidecar spike — bundle, spawn, health-check, raw completion

**User stories**: 6, 9, 21 (partial — foundation for 1)

### What to build

The tracer bullet that de-risks the pillar's biggest unknown: prove the **prebuilt `llama-server` binary bundles, spawns, and serves a real completion** before anything is built on top. Add the pinned binary as a bundled resource (checksum recorded in `docs/native-deps.md`, mirrored in `project.yml`). Spawn it via a bare `Process` call bound to `127.0.0.1:0`, read back the assigned port, poll its health endpoint until ready, then send one raw OpenAI-compatible completion request over loopback HTTP and confirm a real response comes back with a populated `logprobs` field. No abstractions yet — no `SidecarController`, no `LLMClient`, no backoff, no Tier.

### Acceptance criteria

- [x] `llama-server` binary added as a checksum-pinned bundled resource (upstream release/version + SHA-256 recorded in `docs/native-deps.md`); `just gen` + `just app` build clean with the binary embedded in the app bundle.
- [x] A bare `Process` spawn binds `127.0.0.1` on a dynamically assigned (`:0`) port — never a fixed port, never `0.0.0.0` — with the assigned port read back programmatically.
- [x] The spawned process's health endpoint responds OK once ready; a short-timeout poll correctly detects readiness.
- [x] A raw completion request over loopback HTTP (with a Qwen model manually placed at a known path) returns real generated text **and** a populated per-token logprobs array — proving the LLD §3.3 `[ASSUMPTION]` about aligned-logprob output holds for this build.
- [x] The spawned process is killed cleanly on app exit (no orphaned process left running).
- [x] stdout/stderr from the process are captured to `logs/sidecar.log`.
- [x] Per-phase gate green (`just check`, `just app`, 0 lint warnings).

---

## Phase 2: `SidecarController` — lifecycle state machine + backoff + auto-restart

**User stories**: 6, 7, 8, 9, 20

### What to build

Wrap Phase 1's raw spawn mechanics in the LLD §5.1 lifecycle. Build the `LLMRuntime` module's pure heart **fully test-first**: the `SidecarController` protocol + `SidecarState` enum (`stopped`/`launching`/`ready(port:)`/`unhealthy(retryIn:)`/`failed(reason:)`), and a pure backoff-schedule function — given (attempt count, time since last healthy) → next delay or give-up, implementing `1,2,4,8..30s capped`, reset after 60s healthy, `failed` after max retries. Then build the effectful `SidecarManager` shell conforming to `SidecarController`: drives the real process from Phase 1 through this state machine, applying the pure backoff schedule on a real timer, and exposing `startIfNeeded(model:)`, `healthCheck()`, `restart()`, `stop()`.

### Acceptance criteria

- [x] Backoff-schedule function implemented test-first: correct delay sequence for a sequence of failures (`1,2,4,8,...` capped at 30s); a healthy interval > 60s resets the attempt count; exceeding max retries yields the give-up signal. Time is injected (no real sleeps in tests).
- [x] `SidecarState`/`SidecarController` protocol defined; state-transition correctness (`stopped→launching→ready`, `ready→unhealthy→launching`, `unhealthy→failed`) driven test-first by an injected fake process/health-check source — no real process in this suite.
- [x] `SidecarManager` conforms to `SidecarController`, wraps the real `Process` spawn, and applies the pure backoff schedule on a real clock.
- [x] **Integration-verified:** killing the real spawned `llama-server` process causes `SidecarManager` to detect the failure and restart it within the expected backoff window, reaching `ready` again without app intervention. (Live-verified repeatedly; also caught and fixed a real bug — see plan notes / final report.)
- [x] Repeated induced failures (exceeding max retries) surface `.failed(reason:)` rather than hanging or crashing the app; a manual `restart()` recovers from `.failed`. (The give-up-without-crashing half is live-verified against the real process; `restart()`-from-`.failed` is verified test-first against the same production type — no live UI/IPC trigger exists yet to invoke it manually, since no "Retry" affordance is in Phase 2's scope.)
- [x] Per-phase gate green (`just check`, `just app`, 0 lint warnings).

---

## Phase 3: `InferenceClient` — the `LLMClient` seam + concrete client + manual debug hook

**User stories**: 1, 2, 3, 4, 5, 19, 20

### What to build

Close the "prompt → completion" vertical. Build the `LLMClient` protocol (`routeComplete(system:user:grammar:endpoint:) -> RouterCompletion`, `chat(system:messages:params:endpoint:stream:) -> ChatCompletionStream`) and the wire types (`RouterCompletion`, `TokenLogprob`, `ChatMessage`, `SamplingParams`) in `LLMRuntime`, plus a deterministic `MockLLMClient` test-first. Add the concrete `InferenceClient` shell: a `URLSession`-based OpenAI-compatible client that targets the live Sidecar's `LLMEndpoint` (from Phase 2's `SidecarManager.endpoint`), supporting grammar passthrough, logprobs, and streaming. Add a minimal manual debug affordance (not a real feature — P4/P5/P6 don't exist yet to be the true consumer) that triggers one real `chat()` call and displays the result, so there's something to point at live.

### Acceptance criteria

- [x] `LLMClient` protocol + wire types (`RouterCompletion`, `TokenLogprob`, `ChatMessage`, `SamplingParams`, `ChatCompletionStream`) defined in `LLMRuntime`. (`RouterCompletion` deliberately omits LLD §3.3's `decision: RouterDecision` field — `RouterDecision`/Router Contract v2 are P4 `SkillRegistry` scope, out of this PRD's "Out of Scope" list; `routeComplete` is passthrough-only and never produces a decision to put there. Same "minimal placeholder, extend later" precedent as Phase 2's `LLMEndpoint.apiKeyRef: String?`. Similarly, `grammar` is a plain `String`, not LLD's `GBNFGrammar` type, which is also a `SkillRegistry`/P4 type.)
- [x] `MockLLMClient` implemented test-first: deterministic, caller-injectable completions/logprobs/stream chunks, no native process involved. (`Tests/LLMRuntimeTests/MockLLMClientTests.swift`.)
- [x] `InferenceClient` conforms to `LLMClient`: `routeComplete` passes a supplied GBNF grammar through unmodified and returns per-token logprobs aligned to the raw output; `chat` supports both streamed and non-streamed responses. **Architectural note:** `InferenceClient` lives in its own new SwiftPM module (`Sources/InferenceClient/`, sibling to `LLMRuntime`), not `App/` — the plan's original "Architectural decisions" placed it as an App/-layer effectful shell, but `App/` is an Xcode-only target unreachable from `swift test`, so a literal headless integration test against it isn't mechanically possible. Mirroring the `ModelDownloader`/`ModelProvisioning` split, `InferenceClient`'s own request-building/JSON-and-SSE-parsing logic is genuinely unit-tested headlessly against a `URLProtocol` stub (`Tests/InferenceClientTests/`, 9 tests) — no real process, no real network — while `App/AppCoordinator+Sidecar.swift` supplies only the thin "point this at the real Sidecar's endpoint" glue.
- [x] **Headless integration check** — see the architectural note above for why this is split two ways rather than one literal opt-in `swift test` suite against the real Sidecar: (1) **Headless-tested** (`Tests/InferenceClientTests/InferenceClientTests.swift`, part of the normal `just test` gate, no opt-in flag needed): `InferenceClient`'s real request/response wire logic against a `URLProtocol` stub fixturing the exact JSON/SSE shapes captured from the real bundled `llama-server` binary (`b10332`) during this phase's development — grammar passthrough (including an empty-string edge case), non-streamed and SSE-streamed logprobs parsing, cumulative byte-range alignment across streamed chunks, error paths (non-2xx, empty `choices`), and the cloud-endpoint Bearer-auth code path. (2) **Live-verified** (not inside `swift test`): the real `SidecarManager` + real `InferenceClient` + the same dev-smoke-test Qwen2.5-0.5B GGUF Phase 1/2 used (`docs/native-deps.md`) → real `chat()` calls → real completions with real per-token logprobs confirmed in `logs/sidecar.log`'s request/response cycle. This satisfies the PRD's "prompt → completion with logprobs" line for the full stack; a fully-automated opt-in `swift test` suite spawning the real Sidecar was judged not worth building on top of the live verification below, given `App/`'s Xcode-only placement.
- [x] **Manual debug hook:** triggering it renders a real local completion (proves the full stack end-to-end for a person, not just a test). Live-verified (`AIDE_RUN_SIDECAR_CHECK=1 AIDE_SIDECAR_MODEL_PATH=... .build/xcode/Build/Products/Debug/Aide.app/Contents/MacOS/Aide`): `logs/app.log` shows `ready(port: 53671)` then two real completions — `"Sidecar check: debug chat() (non-streamed, 1 chunk(s)) completion: \"Hello! I'm running locally.\""` and `"Sidecar check: debug chat() (streamed, 10 chunk(s)) completion: \"Hello! I'm running this Mac locally.\""` — proving **both** wire modes against the real binary, not just the non-streamed one. See `docs/native-deps.md` § "Dev-only smoke-test Qwen model" for the reproduction steps.
- [x] `isLocal` on `LLMEndpoint` correctly reflects the Sidecar target; the cloud-target code path compiles and type-checks but is not exercised against a real endpoint anywhere in this phase. (`isLocal: true` asserted end-to-end via the live Sidecar endpoint above and in `SidecarLifecycleControllerTests`; the cloud path — `apiKeyRef` → `Authorization: Bearer` header — is headlessly tested in `InferenceClientTests` against the `URLProtocol` stub only, never a real cloud host.)
- [x] Per-phase gate green (`just check`, `just app`, 0 lint warnings).

---

## Phase 4: LLM provisioning logic — the `Tier` refactor + `LlmTierPolicy` + Qwen pins (pure, TDD)

**User stories**: 15, 20, 22

### What to build

The shared, safety-serious foundation for getting the LLM model onto the machine — all pure, all test-first, no network yet, and independent of Phases 1–3 (can be built in parallel with them). Move `Tier` (the `tier8GB`/`tier16GB` enum + RAM-boundary resolution + override) from `SpeechToText.SttTierPolicy` into `ModelProvisioning`, carrying its existing tests along unchanged in intent; update `SttTierPolicy` to consume the moved type with no behavior change. Add `LlmTierPolicy` in `LLMRuntime` (RAM/override → Tier → Qwen `ModelDescriptor`, mirroring `SttTierPolicy.whisperModel(for:)`), and the pinned production `ModelDescriptor`s for Qwen3-8B-Q4_K_M (16GB tier) and Qwen3-4B-Q4_K_M (8GB tier), following the same provenance/pinning pattern as the existing Whisper descriptors.

### Acceptance criteria

- [x] `Tier` moved from `SpeechToText` into `ModelProvisioning`; all existing `SttTierPolicyTests` RAM-boundary coverage (≥16GB, 8GB, boundary, override-wins) passes unchanged against the moved type.
- [x] `SttTierPolicy` reduced to a thin `Tier → Whisper ModelDescriptor` mapper; no behavior change versus pre-move (verified by the carried-over tests).
- [x] `LlmTierPolicy` implemented test-first: RAM boundary cases (≥16GB, 8GB, boundary) → correct Qwen `ModelDescriptor`; onboarding override wins over detected RAM, both directions.
- [x] Qwen3-8B-Q4_K_M and Qwen3-4B-Q4_K_M `ModelDescriptor`s defined with pinned revision, filename, SHA-256, and byte size, with provenance recorded (mirroring `docs/native-deps.md`'s existing Whisper entries).
- [x] All suites green headless; per-phase gate green (`just check`, `just app`, 0 lint warnings).

---

## Phase 5: Real download + onboarding wiring

**User stories**: 10, 11, 12, 13, 14, 15

### What to build

Close the provisioning vertical: the app fetches its own LLM model and starts the Sidecar with it. Wire onboarding's existing tier-confirmation step (already downloading Whisper since P2a Phase 5) to **also** provision the Qwen model via P2a's unchanged `ModelDownloader` — resumable ranged GET, verify against `ModelDescriptor`, honest progress/failure states, skip-if-present-and-verified. Once the Qwen model is verified, call `SidecarManager.startIfNeeded(model:)` from Phase 2 to bring the Sidecar up with the real Tier-appropriate model (retiring Phase 1/3's manually-placed model). Surface a clear "LLM model isn't ready yet" state when the model is missing/corrupt/undownloaded, never a crash or silent failure.

### Acceptance criteria

- [ ] Onboarding's tier-confirmation flow downloads the RAM-appropriate Qwen model alongside Whisper, reusing `ModelDownloader`/`ModelVerification`/`ResumePlan` with no new download code.
- [ ] Interrupting the Qwen download (quit/sleep/dropped network) and relaunching **resumes** from the recorded offset rather than restarting.
- [ ] A re-run after a complete, verified download **skips** re-downloading.
- [ ] A corrupted/tampered downloaded file is caught by verification and surfaces a clear, actionable failure state (never silently used).
- [ ] Once verified, `SidecarManager.startIfNeeded(model:)` is called with the real provisioned Qwen model path; the Sidecar reaches `.ready` end-to-end from a fresh machine with no manually-placed model.
- [ ] A missing/not-yet-provisioned model surfaces as a clear "LLM model isn't ready yet" state rather than a crash.
- [ ] Per-phase gate green (`just check`, `just app`, 0 lint warnings).

---

## Phase 6: Model Residency — idle-unload (Tier-gated)

**User stories**: 16, 17, 18

### What to build

The LLD §5.4 residency behavior the pillar's "Done" line depends on. Build the pure idle-unload state machine test-first: given (Tier, time since last request) → resident/unload decision — 16GB never unloads; 8GB unloads after the idle threshold elapses with no activity, and any activity resets the timer. Wire it into `SidecarManager` on a real timer: on 8GB, an idle Sidecar unloads (via `swapModel`/stop-and-clear-residency) to reclaim RAM, and the next request triggers a reload with a brief visible loading state — never a dropped in-flight context.

### Acceptance criteria

- [ ] Idle-unload state machine implemented test-first: 8GB tier transitions to "unload" once idle time exceeds the threshold with no intervening activity; any activity before the threshold resets the timer; 16GB tier never transitions to "unload" regardless of elapsed idle time. Time is injected — no real sleeps in tests.
- [ ] `SidecarManager` applies the state machine on a real timer: an idle 8GB Sidecar actually unloads; a 16GB Sidecar stays resident through an equivalent idle period.
- [ ] **Manual verification (8GB or forced-tier-override machine):** confirm the Sidecar unloads after the idle period, and a follow-up request reloads it with a visible brief loading state.
- [ ] **Manual verification (16GB machine):** confirm the Sidecar stays resident and a follow-up request is served without a reload.
- [ ] Per-phase gate green (`just check`, `just app`, 0 lint warnings).
