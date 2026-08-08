# PRD — P2a · Speech-to-Text

> First of the two verticals **P2 · Inference Core** (see [`docs/07-implementation-pillars.md`](../docs/07-implementation-pillars.md)) is split into:
> **P2a · Speech-to-Text** (this doc) and **P2b · LLM Runtime** (spec'd next).
> Grounded in [`docs/04-hld.md`](../docs/04-hld.md) §3 and [`docs/05-lld.md`](../docs/05-lld.md) §3.2, §4.1, §2.7, plus §4.3 (Model Residency, STT half).
> Status: draft spec · not yet planned.

## Why P2 is split

P2 · Inference Core is the first pillar that carries **real native binaries** (whisper.cpp, `llama-server`) and **multi-GB network downloads**. It is large enough that a single "done" hides two independent, separately-demoable capabilities:

- **P2a · Speech-to-Text** — audio → text, in-process (whisper.cpp). No subprocess, no HTTP, local-only.
- **P2b · LLM Runtime** — text → text, out-of-process (`llama-server` sidecar) + the OpenAI-compatible client (local + a local-tested cloud target).

They share only the **model-provisioning** mechanism (resumable, SHA-256-pinned download + on-disk verify) and RAM/Tier detection. So P2a builds those shared deep modules once; P2b reuses them. Each vertical is built and demoed to completion on its own. This doc is **P2a**.

## Problem Statement

Aide's entire promise is "talk to your Mac," but today the voice loop is a lie: when the user holds the push-to-talk hotkey and speaks, a **mock** hands back a canned transcript. Nothing is actually listening. Before any command can route, any dictation can be cleaned, or any question can be answered, Aide has to turn **held-hotkey speech into real text, locally, on this machine** — and it has to know when it *misheard*, so that garbled audio never silently becomes a wrong action downstream.

Doing that well is not just "call a transcription API." It means: capturing microphone audio into a buffer gated by the hotkey lifecycle; running whisper.cpp **in-process** (the locked runtime decision — no subprocess for STT) against a model sized to the user's RAM; getting that model onto the machine in the first place (a ~1.5GB download that must be resumable and integrity-verified, because a half-downloaded or corrupted model is worse than none); and reading whisper's own per-segment confidence to reject low-quality captures **before** they reach the router. If any of that is missing, every feature above it is either impossible or unsafe.

## Solution

A local, in-process **speech-to-text vertical** that turns a held hotkey into real recognized text:

- **Microphone capture** opens on push-to-talk keyDown and closes on keyUp, accumulating mono PCM at Whisper's expected sample rate in a ring buffer (**batch-on-release** in v1, with the buffer/engine interface shaped so a future streaming mode drops in without changing callers).
- **whisper.cpp runs in-process** via a **prebuilt, pinned** xcframework (SHA-256-pinned), transcribing the finished utterance and returning transcript text **plus per-segment probability metadata** (avg logprob, no-speech probability, compression ratio).
- A **Segment-Probability Pre-Gate** (the marquee deep module) reads that metadata and decides *pass* vs *re-ask* — dropping non-speech segments, catching repetition/hallucination artifacts, and thresholding overall confidence — so garbage audio becomes an honest "I didn't catch that" instead of a wrong route. It is **lenient in dictation mode** (where output is human-visible) and **strict in command mode** (where output can trigger a skill).
- A **model-provisioning** mechanism gets the Tier-appropriate Whisper model onto the machine: a **resumable**, **pinned-commit + SHA-256-verified** download from the official Hugging Face repo, into a user-discoverable models directory, with a reveal-in-Finder affordance and honest progress/failure states. This is the shared foundation P2b reuses.
- A **Tier policy** maps detected RAM (or the user's onboarding override) to the correct Whisper model, so the machine gets a model it can actually run.

The vertical is proven two ways: **headlessly**, an integration check feeds a fixed sample WAV through the real engine and asserts a sensible transcript + a correct Pre-Gate verdict; and **live**, holding the dictation hotkey and speaking renders a **real transcript in the Overlay** (routing and text-insertion stay deferred — the "result" is just the recognized text). The real engine satisfies the **existing `VoiceSessionDriver` seam** in `AideCore`, so it swaps in for `MockVoiceSessionDriver` with no change to the P1 overlay/coordinator wiring.

Everything above the OS-bound edges (the mic tap, the whisper C call, the network GET) is a **pure, headlessly-tested deep module**: the Pre-Gate, the Tier policy, the download/verify/resume logic, and the ring-buffer accounting. The effectful shells around them are thin and integration-/manually-verified, exactly as P1 treated the `CGEventTap`.

## User Stories

### Real transcription (the vertical)
1. As a user, I want to hold the push-to-talk hotkey, speak, and see my **actual words** appear, so that Aide is genuinely hearing me rather than replaying a canned response.
2. As a user, I want transcription to run entirely **on my Mac** with no network call, so that my voice never leaves the machine.
3. As a user, I want my speech transcribed when I *release* the hotkey (batch-on-release), so that I get one clean transcript of the whole utterance.
4. As a user, I want recognition to handle **Hindi and code-mixed** speech (language auto-detected), so that I can talk the way I actually talk.
5. As a user, I want the transcript to appear quickly after I release the key, so that the interaction feels responsive rather than laggy.
6. As a user, I want the microphone to open only while I'm holding the hotkey and close the instant I release, so that Aide is never listening when I didn't ask it to.

### Honesty about mishearing (the Pre-Gate)
7. As a user, I want Aide to say "I didn't catch that" when my audio was silence or noise, so that it never guesses at nothing.
8. As a user, I want Aide to reject a garbled/looping transcription instead of acting on it, so that a mishearing can't trigger the wrong command.
9. As a user, I want low-confidence captures to prompt a re-ask **in command mode**, so that a wrong route is preferred to be caught rather than executed.
10. As a user dictating text, I want the mishearing bar to be **lenient**, so that Aide doesn't nag me about a human-visible transcript I can just fix myself.
11. As a user, I want a re-ask to be a clear, quick state ("I didn't catch that — try again"), so that recovering from a bad capture is effortless.

### Getting the model onto the machine
12. As a first-time user, I want Aide to download the speech model it needs automatically after I confirm my tier, so that I don't have to hunt for model files.
13. As a user, I want the model download to **resume** if it's interrupted (quit, sleep, dropped Wi-Fi), so that I don't restart a multi-hundred-MB download from zero.
14. As a user, I want the downloaded model **verified against a known checksum**, so that a corrupted or tampered file is caught before it's ever used.
15. As a user, I want to see honest download **progress** and a clear, actionable error if it fails, so that I'm never staring at a frozen setup.
16. As a user, I want the model stored somewhere I can find and reveal in Finder, so that I can see what Aide put on my disk and reclaim the space if I want.
17. As a user, I want Aide to detect that the model is already present and verified and **skip re-downloading**, so that setup is instant on later launches.
18. As a user on a smaller machine, I want Aide to fetch the **RAM-appropriate** speech model (not one my Mac can't run), so that transcription actually works on my hardware.

### Resilience & lifecycle
19. As a user, I want a missing/corrupt/undownloaded model to surface as a clear state ("speech model not ready") rather than a crash or silent failure, so that I always know why nothing happened.
20. As a user, I want the speech model kept **warm** between utterances rather than reloaded each time, so that back-to-back commands stay fast.
21. As a user, I want transcription to behave sanely across sleep/wake and repeated captures, so that Aide keeps working through a normal day.

### Developer-facing (pillar consumers)
22. As a developer building P4 (routing) and P5 (dictation), I want P2a to satisfy the existing `VoiceSessionDriver` seam with a **real** STT-backed driver, so that the overlay/coordinator I inherited from P1 shows real transcripts with no rewiring.
23. As a developer, I want a stable `STTEngine` interface (`ensureLoaded` / `transcribe → Transcription`) with a **mock** conformer, so that P4/P5 can develop against transcription without the native engine present.
24. As a developer, I want the Pre-Gate, Tier policy, model-provisioning, and ring-buffer logic to be **pure and unit-tested headlessly**, so that the risky native/network code is a thin, isolated shell around trustworthy logic.
25. As a developer, I want the whisper.cpp binary **pinned by checksum**, so that builds are reproducible and the native surface can't shift under me.

## Implementation Decisions

**Vertical boundary.** P2a owns audio-in → transcript-out + the Pre-Gate + Whisper-model provisioning. It does **not** own routing, dictation cleanup/insertion, or any LLM call — those are P4/P5 and P2b. The live demo shows a real transcript **in the Overlay**; the "result" summary is a placeholder until routing (P4) exists.

**Native binary posture (locked this session):** whisper.cpp ships as a **prebuilt xcframework**, added as a SwiftPM `.binaryTarget` **pinned by SHA-256 checksum** (and mirrored in `project.yml` for the app). No building whisper from source; no third-party Swift wrapper. The upstream release + its version/commit + checksum are recorded in-repo. Metal/Accelerate acceleration comes from the prebuilt artifact.

**In-process, batch-on-release (locked decisions 6):** STT is in-process via the xcframework's C API — never a subprocess. v1 finalizes on hotkey release; the `STTEngine` interface is defined around *append audio / finalize* semantics (not "give me a file") so a later streaming/partial-decode mode is additive.

**Modules (deep, headlessly tested where possible):**

- **`SpeechToText`** (new SwiftPM module) — the pure heart:
  - **`SegmentPreGate`** — the marquee deep module. Pure function over `Transcription` → a verdict (`pass` / `fail(reason)`), implementing LLD §4.1 exactly: drop non-speech segments (`noSpeechProb` + `avgLogprob` floors), empty-check, repetition/hallucination check (`compressionRatio`), token-weighted utterance-confidence threshold. Parameterized by **mode** (command = strict, all steps; dictation = lenient, threshold step skipped) and by a **provisional-thresholds** struct (values are provisional per the docs — injected, never hardcoded as final, so the future calibration harness can tune them).
  - **`Transcription` / `Segment` / `LanguageHint`** value types (LLD §3.2 shapes), including the token-weighted `utteranceAvgLogprob`.
  - **`STTEngine` protocol** (`ensureLoaded()`, `transcribe(_:language:initialPrompt:) -> Transcription`) — the seam. `initialPrompt` reserves the P5 personalization bias-prompt slot but is unused in P2a.
  - **`SttTierPolicy`** — pure map from injected RAM bytes (+ optional user override) → Tier → the Whisper `ModelDescriptor`. This is the **real** tier→model mapping the P1 onboarding placeholder (`Onboarding/OnboardingTier.swift`) deferred to P2.
  - **`PCMRingBuffer`** — pure ring-buffer accounting (capacity, wraparound, frame/sample-rate bookkeeping) behind the `AudioCaptureBuffer` contract (`start`/`append`/`finalize`/`discard`).
- **`ModelProvisioning`** (new SwiftPM module, **shared with P2b**) — pure core of getting a model onto disk:
  - **`ModelDescriptor`** — repo, pinned commit/revision, filename, expected SHA-256, byte size, on-disk relative path.
  - **`ModelVerification`** — decision logic: given a file (or its streamed hash) + descriptor → `verified` / `mismatch` / `absent`.
  - **`ResumePlan`** — resumable-download math: from `.download-state.json` (offset, expected sha256) + a partial file → the byte range to request next, or "restart" if state is inconsistent.
  - **`DownloadState` codec** — (de)serialize `.download-state.json` (atomic-write contract per LLD §2.7).
  - **`ModelsDirectory`** — path resolution (Application Support vs Caches, user-discoverable), reveal-in-Finder path surfaced to Settings.
- **Effectful shells (integration-/manually-verified, not in the headless unit suite — the P1 `CGEventTap` precedent):**
  - **`WhisperSTTEngine`** — the C-bridge conformer of `STTEngine` that links the xcframework and runs the real decode; keeps the model context **warm** between utterances (residency governed by tier).
  - **`AudioCapture`** — `AVAudioEngine` mic tap → `PCMRingBuffer`, gated by the push-to-talk lifecycle; emits the listening→processing transition the Overlay/Menubar already render.
  - **`ModelDownloader`** — the resumable HTTP `GET` (range requests) that executes a `ResumePlan` and streams bytes to disk + hashes as it goes; the **only** network egress in P2a, and it is one-time model fetch (honors the local-first invariant).
  - **`STTVoiceSessionDriver`** — conforms to the existing `AideCore.VoiceSessionDriver`; on `begin/end` it drives `AudioCapture` → `WhisperSTTEngine` → `SegmentPreGate`, delivering `.transcript(real text)` (or a re-ask state on Pre-Gate fail) then a placeholder `.result`. Swaps in for `MockVoiceSessionDriver` in the app with **no** change to `VoiceSessionCoordinator` or the Overlay.

**Mock conformer.** `MockSTTEngine` (deterministic, returns a canned `Transcription` with injectable segment metadata) ships alongside the real engine so P4/P5 and the Pre-Gate tests never need the native binary.

**Language handling.** `transcribe` takes a `LanguageHint`; default `.auto` for Hindi / code-mixed audio (HLD §3.2). No forced-English.

**Model residency (STT half of HLD §4.3).** The Whisper context loads lazily on first use and stays warm between utterances. The 8GB idle-unload timer is primarily an **LLM** concern (P2b); P2a keeps the Whisper model resident while the app is active (Whisper's footprint is small relative to the LLM). Tier selection picks the model variant; the small-vs-medium 8GB Whisper choice is a build-time constant `SttTierPolicy` treats as a tier parameter.

**Storage (LLD §2.7).** Model blobs + `.download-state.json` live under the user-discoverable models directory; every mutation of `.download-state.json` is atomic (`*.tmp` + `rename(2)`). Zero telemetry; the download URL and checksum are the only network-facing constants.

**No new logic dependencies.** The only new third-party artifact is the pinned whisper.cpp xcframework (authorized this session). No new Swift package dependencies for the pure modules.

## Testing Decisions

**Approach: TDD (red-green-refactor), tests-first**, for every deep module — write the failing test that expresses external behavior, make it pass, refactor. `DangerousCommandScanner` + its XCTest suite is the prior-art pattern (a pure module behind a small interface, exhaustively tested headlessly via `swift test`).

**What makes a good test here:** it drives the module through its **public interface** with injected inputs (a constructed `Transcription`, injected RAM bytes, a fixture partial-download + state file, a fabricated PCM frame stream) and asserts outputs/verdicts — never internal implementation details. No real mic, no real network, no real whisper decode in the headless suite; time and RAM are injected so tests are deterministic.

**Modules under test (all deep modules):**
- **`SegmentPreGate`** — the safety-shaped module, tested hardest. Each LLD §4.1 step: non-speech segments dropped; empty/whitespace → `fail(.noSpeech)`; high `compressionRatio` → `fail(.repetitionArtifact)`; token-weighted mean below floor → `fail(.lowConfidenceSTT)`; a good utterance → `pass`. **Mode matrix:** the same borderline `Transcription` that *fails* the command-mode threshold *passes* the lenient dictation mode (threshold step skipped) — this leniency asymmetry is asserted explicitly. Thresholds come from the injected provisional struct, not literals in the assertions.
- **`SttTierPolicy`** — RAM boundary cases (≥16GB, 8GB, and the boundary) → correct Whisper `ModelDescriptor`; user override wins over detected RAM.
- **`ModelProvisioning`** — `ModelVerification` (`verified`/`mismatch`/`absent`) over fixture bytes; `ResumePlan` (correct next byte-range from a partial file + state; "restart" on inconsistent/oversized state; already-complete → no download); `DownloadState` codec round-trip; `ModelsDirectory` path resolution. Verification correctness is treated with scanner-like seriousness: a **false "verified" on a mismatched file is a defect**, never a tolerated edge.
- **`PCMRingBuffer`** — capacity/wraparound accounting; append-then-finalize yields the expected frame count/order; discard clears; sample-rate/frame bookkeeping.

**Not unit-tested (verified by an integration check + manually, like P1's `CGEventTap`):**
- **Headless integration check** (opt-in, not part of the fast unit gate): a committed short **sample WAV** → real `WhisperSTTEngine` → assert the transcript contains expected words and the Pre-Gate returns the expected verdict. This is the "sample audio → transcript" acceptance from the pillar's "Done," run against the real binary.
- **Live/manual:** hold the dictation hotkey, speak, confirm a real transcript renders in the Overlay; confirm a silent capture yields the re-ask state; confirm a fresh machine downloads → verifies → transcribes end-to-end; confirm the mic opens only while held.

## Out of Scope

- **P2b · LLM Runtime** — the `llama-server` sidecar, the OpenAI-compatible client (local + cloud target), LLM tier/idle-unload, and the Qwen GGUF download. P2b **reuses** P2a's `ModelProvisioning`. (Spec'd next.)
- **Routing / Skill Registry / dispatch** — **P4**. P2a delivers a transcript; it does not decide what the transcript *means*. The live "result" is a placeholder until P4.
- **Dictation cleanup (tone pass), Text Insertion, Personalization Dictionary** — **P5**. `transcribe`'s `initialPrompt` reserves the bias-prompt slot but P2a sends nothing into it.
- **Streaming / partial decode** — architected-for (append/finalize seam) but not implemented in v1 (batch-on-release).
- **Wake word** continuous tap — the low-cost continuous capture path is a later, opt-in feature; P2a's capture is push-to-talk-gated only.
- **The confidence *calibration harness*** (the ~1-week threshold tuning, LLD §7) — P2a ships the **provisional** thresholds behind an injectable struct so calibration can tune them later; building the harness itself is out of scope here.
- **Final threshold values** — provisional per the docs; not to be hardcoded as final.
- **Cloud/BYOK anything** — STT is local-only; no cloud target exists in P2a.

## Further Notes

- **Independence via the seam:** P2a sits on `AideCore` (the `VoiceSessionDriver` seam + shared types) and on P1's Overlay/Hotkey/Onboarding shells, but depends on **no** feature pillar. The real `STTEngine` replacing `MockVoiceSessionDriver` is the whole point of the P1 seam paying off for the first time.
- **Safety framing for the Pre-Gate:** it is not the Dangerous-Command Scanner, but it shares the scanner's *posture* — loose-and-safe, prefer a re-ask over a bad route; a false "this audio is good" that lets garbage reach the router is the failure mode to design against.
- **"Done" (acceptance demo):** on the M2/16GB reference machine — confirm tier in onboarding → Whisper model downloads (resumable) + verifies → hold the dictation hotkey and speak → a **real transcript** renders in the Overlay → a silent/garbled capture yields the honest re-ask → the headless integration check (sample WAV → transcript + Pre-Gate verdict) is green, and all deep-module unit suites are green via `swift test`.
- **Relevant NFRs (design toward):** transcription feels responsive after release; model kept warm; mic open strictly only while held; every failure (no model, corrupt model, no-speech) surfaces a human-readable state.
- **Reference machine:** Apple M2 / 16GB, macOS 14+, Apple Silicon only.
- This PRD is the input to the P2a **phased plan** (`/prd-to-plan` → `plans/P2a-speech-to-text.md`), authored next. **P2b · LLM Runtime** gets its own PRD once P2a lands.
