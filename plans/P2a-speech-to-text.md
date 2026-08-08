# Plan: P2a · Speech-to-Text

> Source PRD: [`specs/P2a-speech-to-text.md`](../specs/P2a-speech-to-text.md) — first of the two verticals P2 · Inference Core is split into (P2a · Speech-to-Text here; P2b · LLM Runtime spec'd next).
> Grounded in `docs/04-hld.md` §3 and `docs/05-lld.md` §3.2, §4.1, §4.3 (STT half), §2.7.
> Execution: `/execute-plan --tdd`, **one phase at a time**, each gated + paused for review before the next.

## Architectural decisions

Durable decisions that apply across all phases:

- **Native binary (locked):** whisper.cpp ships as a **prebuilt xcframework**, added as a SwiftPM `.binaryTarget` **pinned by SHA-256 checksum**, and mirrored in `project.yml` for the app target. No building from source; no third-party Swift wrapper. The upstream release tag/commit + checksum are recorded in-repo. Acceleration (Metal/Accelerate) comes from the prebuilt artifact.
- **New SwiftPM modules:**
  - **`SpeechToText`** (pure, headless) — `SegmentPreGate`; the `Transcription` / `Segment` / `LanguageHint` value types; the `STTEngine` protocol + `MockSTTEngine`; `SttTierPolicy`; `PCMRingBuffer` + the `AudioCaptureBuffer` contract.
  - **`ModelProvisioning`** (pure, headless, **shared with P2b**) — `ModelDescriptor`, `ModelVerification`, `ResumePlan`, `DownloadState` codec, `ModelsDirectory`.
  - Both registered in `Package.swift` (+ test targets) and, where the app links them, `project.yml` → `just gen`.
- **Effectful shells (App/ layer, integration-/manually-verified — the P1 `CGEventTap` precedent, NOT in the headless unit gate):** `WhisperSTTEngine` (C-bridge conformer of `STTEngine`), `AudioCapture` (AVAudioEngine mic tap → `PCMRingBuffer`), `ModelDownloader` (resumable ranged HTTP GET), `STTVoiceSessionDriver` (real conformer of `AideCore.VoiceSessionDriver`).
- **The seam pays off:** the real STT driver satisfies the **existing** `AideCore.VoiceSessionDriver`; it swaps in for `MockVoiceSessionDriver` at `App/AppCoordinator.swift` (currently line 67) with **no** change to `VoiceSessionCoordinator` or the Overlay.
- **Key data shapes (durable):**
  - `Transcription { text; language; segments: [Segment]; utteranceAvgLogprob }`; `Segment { text; tStart; tEnd; avgLogprob; noSpeechProb; compressionRatio; tokenCount }` (LLD §3.2). `utteranceAvgLogprob` = token-count-weighted mean of retained segments.
  - `ModelDescriptor { repo; pinnedRevision; filename; expectedSHA256; byteSize; onDiskRelativePath }`.
  - `.download-state.json { offset; expectedSHA256 }`, written atomically (`*.tmp` + `rename(2)`, LLD §2.7).
  - Model blobs live under a **user-discoverable** models directory (Application Support, or Caches with a reveal-in-Finder affordance).
- **STT semantics (locked):** in-process, **batch-on-release**; the engine interface is *append audio / finalize* (not "give me a file") so a future streaming mode is additive. `LanguageHint` defaults to `.auto` (Hindi / code-mixed).
- **Pre-Gate (LLD §4.1):** drop non-speech segments → empty-check → repetition/hallucination check → token-weighted confidence threshold. **Command mode = strict** (all steps); **dictation mode = lenient** (threshold step skipped). Thresholds are **provisional**, passed in via an injected struct — never hardcoded as final (the calibration harness tunes them later; that harness is out of scope for P2a).
- **Local-first invariant:** the **only** network egress in P2a is the one-time Whisper-model download (ranged GET to the pinned Hugging Face revision). Nothing else leaves the machine. Zero telemetry.
- **Tier policy:** RAM (or the user's onboarding override) → Tier → Whisper `ModelDescriptor` (16GB = large-v3-turbo; 8GB = the locked small/medium variant). Override wins over detected RAM. Whisper context stays **warm/resident** while the app is active (idle-unload is an LLM-sized concern → P2b).
- **Testing posture:** TDD (red-green-refactor), tests-first, for every deep module, headless via `swift test` — the `DangerousCommandScanner` suite is the prior-art pattern. Native/mic/network shells are excluded from the fast unit gate and verified by an opt-in integration check (committed sample WAV → real transcript) + manual test.
- **Per-phase gate (MUST, all phases):** `just check` green (format-check + SwiftLint + `swift build` + `swift test`) **and** `just app` builds **and** SwiftLint reports **0 warnings**; new modules registered in `Package.swift`/`project.yml` and `just gen` run where the app links them. Phase is not "done" until these pass and the user has reviewed.

---

## Phase 1: Native STT spike — sample WAV → real transcript

**User stories**: 1 (partial — real words, file-fed not mic yet), 2, 4, 23, 25

### What to build

The tracer bullet that de-risks the entire pillar: prove the **prebuilt whisper.cpp xcframework links and decodes in-process** before anything is built on top. Add the pinned xcframework as a SwiftPM `.binaryTarget` (checksum recorded) and wire it into `project.yml`. Create the `SpeechToText` module with the `STTEngine` seam (`ensureLoaded()`, `transcribe(_:language:initialPrompt:) -> Transcription`), the `Transcription`/`Segment`/`LanguageHint` value types (with the token-weighted `utteranceAvgLogprob`), and a deterministic `MockSTTEngine`. Add the `WhisperSTTEngine` shell (C bridge) that loads a **manually-placed** Whisper model from a known path and transcribes a **committed short sample WAV**, returning real text + per-segment probability metadata. `initialPrompt` exists but is unused (reserves the P5 bias-prompt slot). No mic, no download, no Pre-Gate yet.

### Acceptance criteria

- [x] whisper.cpp xcframework added as a checksum-pinned SwiftPM `.binaryTarget` (upstream tag/commit + SHA-256 recorded in-repo) and mirrored in `project.yml`; `just gen` + `just app` build clean.
- [x] `SpeechToText` module + test target registered in `Package.swift`.
- [x] `Transcription`/`Segment`/`LanguageHint` value types exist; `utteranceAvgLogprob` (token-count-weighted mean) is **unit-tested test-first** over constructed segments, including the empty/zero-token edge.
- [x] `STTEngine` protocol + `MockSTTEngine` exist; the mock returns a caller-injectable `Transcription` (deterministic, no native binary).
- [x] `WhisperSTTEngine` shell transcribes a committed sample WAV (model manually placed) → a transcript whose text contains the expected words, with populated per-segment `avgLogprob`/`noSpeechProb`/`compressionRatio`. Verified by an **opt-in headless integration check** (excluded from the fast unit gate).
- [x] `LanguageHint.auto` is the default path (no forced-English).
- [x] Per-phase gate green (`just check`, `just app`, 0 lint warnings).

---

## Phase 2: The Pre-Gate — honesty about mishearing

**User stories**: 7, 8, 9, 10, 11

### What to build

`SegmentPreGate` built **fully test-first** — the marquee deep module and the safety-shaped core of P2a. Implement LLD §4.1 exactly: drop non-speech segments (`noSpeechProb` + `avgLogprob` floors), empty/whitespace-only → `fail(.noSpeech)`, `compressionRatio` over the ceiling → `fail(.repetitionArtifact)`, token-weighted utterance confidence below floor → `fail(.lowConfidenceSTT)`, else `pass`. Parameterize by **mode** (command = strict/all-steps; dictation = lenient/threshold-skipped) and by an **injected provisional-thresholds struct**. Wire the Pre-Gate after `WhisperSTTEngine` in the still-file-fed path so its verdict is observable end-to-end. No mic yet.

### Acceptance criteria

- [x] `SegmentPreGate` implemented test-first; each §4.1 step has a dedicated failing-then-passing test: non-speech drop, `.noSpeech`, `.repetitionArtifact`, `.lowConfidenceSTT`, and `pass`.
- [x] **Mode-asymmetry test:** one borderline `Transcription` that `fail`s command mode `pass`es dictation mode (threshold step skipped) — asserted explicitly.
- [x] Thresholds come from the injected provisional struct; **no threshold literal appears in an assertion** (calibration can retune without touching tests).
- [x] Verify-correctness posture: a low-quality sample clip run through the file-fed path returns the expected `fail(reason)`; a good clip returns `pass`.
- [x] `SpeechToText` test suite covers the Pre-Gate exhaustively; all green headless.
- [x] Per-phase gate green (`just check`, `just app`, 0 lint warnings).

---

## Phase 3: Live — hold hotkey → speak → real transcript in the Overlay

**User stories**: 1, 3, 5, 6, 20, 21, 22

### What to build

Make it real and user-visible — the "complete vertical." Build `PCMRingBuffer` (**test-first**) behind the `AudioCaptureBuffer` contract (`start`/`append`/`finalize`/`discard`). Add the `AudioCapture` shell (AVAudioEngine mic tap → ring buffer, opened on push-to-talk keyDown and closed on keyUp). Add `STTVoiceSessionDriver` conforming to `AideCore.VoiceSessionDriver`: on `begin/end` it drives `AudioCapture` → `WhisperSTTEngine` → `SegmentPreGate`, delivering `.transcript(real text)` on `pass` (or a re-ask state on `fail`) then a **placeholder** `.result` (routing arrives in P4). Swap it in for `MockVoiceSessionDriver` at `App/AppCoordinator.swift`. Keep the Whisper context warm between utterances.

### Acceptance criteria

- [ ] `PCMRingBuffer` implemented test-first: capacity/wraparound accounting, append→finalize frame count/order, `discard` clears, sample-rate/frame bookkeeping.
- [ ] `AudioCapture` opens the mic only while the hotkey is held and closes on release (mic never open otherwise); emits the listening→processing transition the Overlay/Menubar already render.
- [ ] `STTVoiceSessionDriver` conforms to `VoiceSessionDriver` and is swapped in for `MockVoiceSessionDriver` in `AppCoordinator` with **no** change to `VoiceSessionCoordinator` or the Overlay.
- [ ] **Live demo:** hold the dictation hotkey, speak → a real transcript renders in the Overlay; a silent/garbled capture → the honest re-ask state.
- [ ] Whisper model context is loaded lazily and kept warm across back-to-back captures; behavior is sane across repeated captures and sleep/wake.
- [ ] `onUpdate` is delivered on the main actor (matches the seam contract).
- [ ] Per-phase gate green (`just check`, `just app`, 0 lint warnings).

---

## Phase 4: Provisioning logic (pure, TDD)

**User stories**: 14, 17, 18 (foundation for 12–16)

### What to build

The shared, safety-serious foundation for getting a model onto the machine — **all pure, all test-first**, no network yet. Build the `ModelProvisioning` module: `ModelDescriptor`; `ModelVerification` (given a file/streamed hash + descriptor → `verified`/`mismatch`/`absent`); `ResumePlan` (from `.download-state.json` + a partial file → the next byte-range, or "restart" on inconsistent/oversized state, or "complete" → no download); the `DownloadState` codec (round-trip, atomic-write contract); `ModelsDirectory` (path resolution, user-discoverable, reveal-in-Finder path). Build `SttTierPolicy` (RAM + override → Tier → Whisper `ModelDescriptor`) in `SpeechToText`. Not user-facing on its own — verified by its unit suites.

### Acceptance criteria

- [ ] `ModelProvisioning` module + test target registered in `Package.swift`.
- [ ] `ModelVerification` tested test-first over fixture bytes: `verified` on match, `mismatch` on a tampered byte, `absent` on missing file. **A false `verified` on a mismatched file is treated as a defect** (scanner-serious) — asserted directly.
- [ ] `ResumePlan` tested: correct next byte-range from a partial file + state; "restart" on inconsistent/oversized state; "complete" when already whole → no download requested.
- [ ] `DownloadState` codec round-trips; writes go through the atomic (`*.tmp` + rename) contract.
- [ ] `ModelsDirectory` resolves the models path and exposes the reveal-in-Finder path; tested.
- [ ] `SttTierPolicy` tested at RAM boundaries (≥16GB, 8GB, boundary) → correct `ModelDescriptor`; onboarding override wins over detected RAM.
- [ ] All suites green headless; per-phase gate green (`just check`, `just app`, 0 lint warnings).

---

## Phase 5: Real download + onboarding wiring

**User stories**: 12, 13, 15, 16, 19

### What to build

Close the vertical: the app provisions its own model. Add the `ModelDownloader` shell — a resumable ranged HTTP `GET` (the one allowed network egress) that executes a `ResumePlan`, streams bytes to disk, and hashes as it streams. Wire onboarding's tier-confirmation step → download the RAM-appropriate Whisper model → verify against `ModelDescriptor` → the engine loads from the provisioned path (retiring Phase 1's manual placement). Surface honest **progress**, an actionable **failure** state, **skip-if-present-and-verified**, and a **model-not-ready** state (missing/corrupt/undownloaded → clear human-readable state, never a crash or silent failure).

### Acceptance criteria

- [ ] `ModelDownloader` performs a resumable ranged GET, streams to disk, and hashes-as-it-streams; on interruption (quit/sleep/dropped network) a re-run **resumes** from the recorded offset rather than restarting.
- [ ] Onboarding tier-confirm → RAM-appropriate model downloads → verifies → `WhisperSTTEngine` loads from the provisioned path (no manual placement).
- [ ] A corrupt/mismatched download is caught by verification and surfaced (not used); an already-present verified model is **skipped** (instant on later launches).
- [ ] Download **progress** and an actionable **failure** message are shown; a missing/undownloaded model surfaces a **"speech model not ready"** state, not a crash.
- [ ] Model blob + `.download-state.json` land under the user-discoverable models directory with a working reveal-in-Finder affordance; `.download-state.json` mutations are atomic.
- [ ] The download URL + checksum are the only network-facing constants; no other egress.
- [ ] **Full-vertical demo:** on a fresh machine — confirm tier → auto-download + verify → hold hotkey + speak → real transcript in the Overlay; plus the opt-in integration check (sample WAV → transcript + Pre-Gate verdict) green.
- [ ] Per-phase gate green (`just check`, `just app`, 0 lint warnings).
