# Native dependencies

Aide bundles two prebuilt native artifacts: the whisper.cpp xcframework (P2a ·
Speech-to-Text) and the `llama-server` executable (P2b · LLM Runtime). Both are **pinned
by SHA-256 checksum** and never built from source — but they're wired in differently,
because one is a linkable library and the other is a spawnable subprocess (see
"How it is wired" under each).

## whisper.cpp (STT engine)

| Field | Value |
| --- | --- |
| Upstream | [`ggml-org/whisper.cpp`](https://github.com/ggml-org/whisper.cpp) |
| Release tag | `v1.9.2` |
| Commit | `306c88f4d1286aec1bf96e544632897886af5501` |
| Artifact | `whisper-v1.9.2-xcframework.zip` (official release asset) |
| URL | https://github.com/ggml-org/whisper.cpp/releases/download/v1.9.2/whisper-v1.9.2-xcframework.zip |
| SHA-256 | `af74fed13ea7f2d5ca2a39d9f58ec177713fafd7cab63aef4e27b79f3ceca80b` |
| Zip size | 53,575,921 bytes |
| Module | `import whisper` (framework module; macOS slice `macos-arm64_x86_64`) |
| Acceleration | Metal + Accelerate (from the prebuilt artifact) |

### How it is wired

- **`Package.swift`** declares it as a checksum-pinned remote binary target:
  `.binaryTarget(name: "whisper", url: <URL above>, checksum: <SHA-256 above>)`.
  SwiftPM downloads the zip once, verifies it against the checksum, and extracts the
  nested `build-apple/whisper.xcframework`. Only `WhisperSTTEngine` depends on it.
- **`project.yml`** mirrors it for the Xcode app target by depending on the
  `WhisperSTTEngine` product (which transitively brings the whisper framework), so
  `just gen` + `just app` embed/link it in `Aide.app`.

### Recomputing / rotating the checksum

```bash
curl -sL -o whisper.zip \
  https://github.com/ggml-org/whisper.cpp/releases/download/v1.9.2/whisper-v1.9.2-xcframework.zip
swift package compute-checksum whisper.zip   # must equal the SHA-256 above
```

Bumping the version means: update the tag, URL, and checksum here **and** in
`Package.swift`, then re-run `just check` + `just app`.

## llama-server (LLM Sidecar)

`llama-server` is the **sole Sidecar** (P2b · LLM Runtime, locked decision; Phase 1 of
`plans/P2b-llm-runtime.md`) — a **spawnable executable**, not a linkable library. This is
the load-bearing difference from whisper.cpp above: whisper ships as an xcframework and
is a SwiftPM `.binaryTarget` that `WhisperSTTEngine` links and calls into in-process;
`llama-server` runs out-of-process (docs/03-architecture.md's D5 fault-isolation
rationale) and SwiftPM's `.binaryTarget` mechanism **cannot** express "embed this raw
executable as a bundled resource" — that mechanism is for linking, not subprocess
bundling. So it is fetched, checksum-verified, and placed by a `just` recipe instead of
by SwiftPM, then embedded into `Aide.app` by `project.yml`/XcodeGen.

| Field | Value |
| --- | --- |
| Upstream | [`ggml-org/llama.cpp`](https://github.com/ggml-org/llama.cpp) |
| Release tag | `b10332` (llama.cpp's CI build-number releases — every merge to master is built and published; there is no separate semver-tagged "stable" release channel for the prebuilt binaries, unlike whisper.cpp) |
| Commit | `61141f1487e63d9b22aec193131253bb2ea0800c` |
| Artifact | `llama-b10332-bin-macos-arm64.tar.gz` (official release asset) |
| URL | https://github.com/ggml-org/llama.cpp/releases/download/b10332/llama-b10332-bin-macos-arm64.tar.gz |
| SHA-256 | `2f5b9eef98f5376465cd00402ef3a68eaac1f4b11f9de0a6a59b1307255399a8` |
| Archive size | 11,019,214 bytes |
| Acceleration | Metal + Accelerate (from the prebuilt artifact; ggml compiles its Metal shaders at runtime, no separate `.metallib` resource needed) |

**Cross-checked provenance:** GitHub's release-asset API exposes a `digest` field
alongside each asset — an independent, second source for the same hash without
re-downloading:

```bash
gh api repos/ggml-org/llama.cpp/releases/tags/b10332 \
  | python3 -c "import json,sys; d=json.load(sys.stdin); \
      print([a['digest'] for a in d['assets'] if 'macos-arm64' in a['name']])"
# => sha256:2f5b9eef98f5376465cd00402ef3a68eaac1f4b11f9de0a6a59b1307255399a8
```

This matched the locally computed `shasum -a 256` exactly — two independent sources
(GitHub's own recorded digest + a local hash of the downloaded bytes) agreeing.

### Why the whole directory, not just the binary

`llama-server` is **dynamically linked** against ten sibling `.dylib`s from the same
release archive (`libllama-server-impl`, `libllama-common`, `libmtmd`, `libllama`,
`libggml`, `libggml-cpu`, `libggml-blas`, `libggml-metal`, `libggml-rpc`,
`libggml-base`) — unlike whisper's xcframework, which is self-contained. `otool -l
llama-server` shows `LC_RPATH = @loader_path`, i.e. dyld resolves every `@rpath/lib*.dylib`
dependency relative to **the directory containing the executable itself**. So the
binary and all ten dylibs must be bundled together, flat, in one directory — ship the
executable alone and it fails to launch (`dyld: Library not loaded`). Each file already
carries its own valid ad-hoc/linker-signed Mach-O signature from the upstream CI build
(`codesign -dv` shows `flags=0x20002(adhoc,linker-signed)`), which survives a plain file
copy untouched — no re-signing step is needed to embed them.

### How it is wired

- **`just vendor-llama-server`** (in `justfile`) downloads the release tarball, verifies
  its SHA-256 against the pin above, extracts it, and copies the executable + the ten
  dylibs + `LICENSE` into `Vendor/bin/llama-server/` (gitignored — `Vendor/README.md`),
  flattening away the archive's versioned-symlink names into the real files under the
  exact filenames `@rpath` expects. Idempotent — skips the fetch once the binary is
  present. This is the closest equivalent to SwiftPM's automatic binaryTarget fetch for
  an artifact type that mechanism doesn't support.
- **`just gen`** depends on `vendor-llama-server`, so a fresh checkout fetches the
  binary automatically before XcodeGen ever runs (XcodeGen validates referenced source
  paths exist at generation time).
- **`project.yml`** adds `Vendor/bin/llama-server` as a `type: folder` source with a
  dedicated **Copy Files** build phase (`destination: resources`) on the `Aide` target —
  NOT a `resources:`/Copy Bundle Resources entry, and not a `.binaryTarget` in
  `Package.swift` (there is nothing to link; `llama-server` is invoked via `Process`, not
  called into). A folder reference copies the whole directory as one atomic, permission-
  and-signature-preserving unit. It lands at `Contents/Resources/llama-server/` in the
  built app (verified: `find Aide.app/Contents/Resources -iname '*llama*'`), resolved at
  runtime via `Bundle.main.resourceURL` (`App/LlamaServerProcessSource.swift`).

### Recomputing / rotating the checksum

```bash
gh api repos/ggml-org/llama.cpp/releases/latest   # find the current build tag
curl -sL -o llama.tar.gz \
  https://github.com/ggml-org/llama.cpp/releases/download/<tag>/llama-<tag>-bin-macos-arm64.tar.gz
shasum -a 256 llama.tar.gz   # cross-check against `gh api .../releases/tags/<tag>`'s digest field
```

Bumping the version means: update `_llama_release`/`_llama_asset`/`_llama_sha256` in
`justfile`, delete `Vendor/bin/llama-server/` to force a re-fetch, update this table, then
re-run `just check` + `just app`.

### Dev-only smoke-test Qwen model (Phase 1, reused by Phases 2-3)

Phase 1's tracer bullet needed *some* real GGUF to prove the spawn → health-check →
completion → logprobs flow end-to-end without downloading a multi-GB production model.
Phase 2 reuses the same manually-placed model for its opt-in `SidecarManager`
integration/manual verification (`App/AppCoordinator+Sidecar.swift`); Phase 3 reuses it
again for its manual debug hook (one real non-streamed `chat()` call and one real
streamed `chat()` call through the real `InferenceClient`) — never provisioned by the
app, never part of any automated gate, and **not committed** (`*.gguf` in `.gitignore`).

- **Model:** [`Qwen/Qwen2.5-0.5B-Instruct-GGUF`](https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF)
  (official Qwen org), file `qwen2.5-0.5b-instruct-q2_k.gguf` — the smallest quant Qwen
  themselves publish for this model (~396 MiB), chosen over third-party requantizers for
  the same first-party-provenance reason as the production pins above.
- **SHA-256:** `9ee36184e616dfc76df4f5dd66f908dbde6979524ae36e6cefb67f532f798cb8`
  (matches the HF tree API's `lfs.oid` for this file).
- **To reproduce the manual verification:**
  ```bash
  curl -sL -o /tmp/qwen-dev-test.gguf \
    "https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/qwen2.5-0.5b-instruct-q2_k.gguf"
  AIDE_RUN_SIDECAR_CHECK=1 AIDE_SIDECAR_MODEL_PATH=/tmp/qwen-dev-test.gguf \
    .build/xcode/Build/Products/Debug/Aide.app/Contents/MacOS/Aide
  ```
  Then watch `~/Library/Application Support/Aide/logs/app.log` for "Sidecar check: state
  -> ..." transitions, then (Phase 3) two "Sidecar check: debug chat() ..." lines — one
  `(non-streamed, 1 chunk(s))`, one `(streamed, N chunk(s))` with `N > 1` — each with the
  real rendered completion text; `logs/sidecar.log` carries the real `llama-server`
  startup/request log underneath. Live-verified during Phase 3's development, e.g.:
  ```
  Sidecar check: state -> ready(port: 53671)
  Sidecar check: debug chat() (non-streamed, 1 chunk(s)) completion: "Hello! I'm running locally."
  Sidecar check: debug chat() (streamed, 10 chunk(s)) completion: "Hello! I'm running this Mac locally."
  ```
  To exercise Phase 2's crash → auto-restart behavior, find the running child with
  `pgrep -fl llama-server` and `kill` it — `app.log` shows `ready` -> `unhealthy` ->
  `launching` -> `ready` again within the backoff window. This is **not** the production
  Qwen3-8B/4B model (see "Qwen models" below, Phase 4's pins) — Phase 5 retires this
  manual step once real provisioning wires a Tier-appropriate model in.

## Whisper models (NOT committed)

Model blobs are large and are **not** in git (see `.gitignore`). In P2a Phase 1 the spike
model is placed manually; Phase 5 adds real resumable, checksum-verified provisioning for
the two **production** tier models (`SpeechToText.SttTierPolicy`/`ModelProvisioning`).

- **Location:** `~/Library/Application Support/Aide/models/` (`ModelsDirectory`; a
  reveal-in-Finder affordance lives in Settings → Data — User Story 16).
- **Spike/test model:** `ggml-base.en.bin` (~148 MB), SHA-256
  `a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002`, from
  [`ggerganov/whisper.cpp`](https://huggingface.co/ggerganov/whisper.cpp) on Hugging Face.
  Used only by the opt-in integration check below — never provisioned by the app itself.

### Production tier pins (P2a Phase 5)

Both pinned to the same HF commit revision (`docs/04-hld.md` §4.3's Tier→model table).
`SttTierPolicy` maps detected RAM (or the onboarding-confirmed override) to one of these;
`ModelDownloader`/`ModelProvisioner` fetch and verify whichever the confirmed Tier needs.

| Field | 16GB tier | 8GB tier |
| --- | --- | --- |
| Repo | [`ggerganov/whisper.cpp`](https://huggingface.co/ggerganov/whisper.cpp) | same |
| Revision | `5359861c739e955e79d9a303bcbc70fb988958b1` | same |
| Filename | `ggml-large-v3-turbo.bin` | `ggml-small.bin` (**multilingual** — not `.en`, needed for `.auto` Hindi/code-mixed detection) |
| SHA-256 | `1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69` | `1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b` |
| Byte size | 1,624,555,275 (~1.51 GiB) | 487,601,967 (~465 MiB) |
| Download URL | `https://huggingface.co/ggerganov/whisper.cpp/resolve/<revision>/ggml-large-v3-turbo.bin` | `https://huggingface.co/ggerganov/whisper.cpp/resolve/<revision>/ggml-small.bin` |

**How these were obtained without downloading either multi-GB file:** the HF tree API
exposes each LFS file's SHA-256 and byte size directly —

```bash
curl -s "https://huggingface.co/api/models/ggerganov/whisper.cpp/tree/main" \
  | python3 -c "import json,sys; d=json.load(sys.stdin); \
      print([e for e in d if e['path'] in ('ggml-large-v3-turbo.bin','ggml-small.bin')])"
```

which returns each file's `lfs.oid` (= SHA-256) and `lfs.size`; the repo's current commit
comes from `GET /api/models/ggerganov/whisper.cpp`'s `sha` field. Both were **cross-checked**
against a second, independent HF endpoint — a `HEAD` request to the `resolve` URL, which
echoes the same digest/size/commit in response headers without transferring the body:

```bash
curl -sI "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin" \
  | grep -iE "x-linked-etag|x-linked-size|x-repo-commit"
```

`x-linked-etag` matched `lfs.oid`, `x-linked-size` matched `lfs.size`, and `x-repo-commit`
matched the tree API's `sha` for both files — two independent HF endpoints agreeing, with
zero bytes of either model transferred. The pins are recorded as `ModelDescriptor` statics
in `Sources/SpeechToText/SttTierPolicy.swift` and asserted directly in `SttTierPolicyTests`.

**Rotating a pin:** re-run both commands above for the new revision/filename, update the
`ModelDescriptor` statics and this table, then re-run `just check`. Never hand-compute a
pin by downloading the file in CI or in this repo — the guardrail above is the point.

### Running the opt-in STT integration check

The real-decode check (`WhisperSTTEngineTests`) is excluded from the fast unit gate. With
the spike model placed above:

```bash
AIDE_RUN_STT_INTEGRATION=1 swift test --filter WhisperSTTEngineIntegrationTests
```

Without the env var or the model, it `XCTSkip`s, so `just test` stays green on a machine
that has neither.

## Qwen models (NOT committed)

P2b's LLM Runtime reuses the same posture as the Whisper models above: not committed to
git (see `.gitignore`), fetched into the same user-discoverable models directory, and
tier-mapped by a pure policy — `LLMRuntime.LlmTierPolicy` (P2b Phase 4), mirroring
`SpeechToText.SttTierPolicy` for the LLM half of `docs/04-hld.md` §4.3's Tier→model table.

- **Location:** `~/Library/Application Support/Aide/models/` (`ModelsDirectory`, shared
  with the Whisper blobs).
- **Format:** GGUF, quantized `Q4_K_M` (the locked quantization for both tiers).
- **Repo choice:** the **official `Qwen` Hugging Face org** GGUF repos
  (`Qwen/Qwen3-8B-GGUF`, `Qwen/Qwen3-4B-GGUF`) — first-party quantizations published by
  the model authors themselves, rather than a third-party requantizer, for the strongest
  provenance guarantee available.

### Production tier pins (P2b Phase 4)

`LlmTierPolicy` maps detected RAM (or the onboarding-confirmed override) to one of these;
`ModelDownloader`/`ModelProvisioner` (Phase 5) fetch and verify whichever the confirmed
Tier needs. Unlike the Whisper pair (one repo, one shared revision), the two Qwen
quantizations live in **two separate official repos**, each pinned to its own revision.

| Field | 16GB tier | 8GB tier |
| --- | --- | --- |
| Repo | [`Qwen/Qwen3-8B-GGUF`](https://huggingface.co/Qwen/Qwen3-8B-GGUF) | [`Qwen/Qwen3-4B-GGUF`](https://huggingface.co/Qwen/Qwen3-4B-GGUF) |
| Revision | `7c41481f57cb95916b40956ab2f0b139b296d974` | `bc640142c66e1fdd12af0bd68f40445458f3869b` |
| Filename | `Qwen3-8B-Q4_K_M.gguf` | `Qwen3-4B-Q4_K_M.gguf` |
| SHA-256 | `d98cdcbd03e17ce47681435b5150e34c1417f50b5c0019dd560e4882c5745785` | `7485fe6f11af29433bc51cab58009521f205840f5b4ae3a32fa7f92e8534fdf5` |
| Byte size | 5,027,783,488 (~4.68 GiB) | 2,497,280,256 (~2.33 GiB) |
| Download URL | `https://huggingface.co/Qwen/Qwen3-8B-GGUF/resolve/<revision>/Qwen3-8B-Q4_K_M.gguf` | `https://huggingface.co/Qwen/Qwen3-4B-GGUF/resolve/<revision>/Qwen3-4B-Q4_K_M.gguf` |

**How these were obtained without downloading either multi-GB file:** same method as the
Whisper pins above — the HF tree API exposes each LFS file's SHA-256 and byte size
directly —

```bash
curl -s "https://huggingface.co/api/models/Qwen/Qwen3-8B-GGUF/tree/main" \
  | python3 -c "import json,sys; d=json.load(sys.stdin); \
      print([e for e in d if e['path'] == 'Qwen3-8B-Q4_K_M.gguf'])"
curl -s "https://huggingface.co/api/models/Qwen/Qwen3-4B-GGUF/tree/main" \
  | python3 -c "import json,sys; d=json.load(sys.stdin); \
      print([e for e in d if e['path'] == 'Qwen3-4B-Q4_K_M.gguf'])"
```

which returns each file's `lfs.oid` (= SHA-256) and `lfs.size`; each repo's current commit
comes from `GET /api/models/Qwen/Qwen3-<size>-GGUF`'s `sha` field. Both were
**cross-checked** against a second, independent HF endpoint — a `HEAD` request to the
`resolve` URL, which echoes the same digest/size/commit in response headers without
transferring the body:

```bash
curl -sI "https://huggingface.co/Qwen/Qwen3-8B-GGUF/resolve/main/Qwen3-8B-Q4_K_M.gguf" \
  | grep -iE "x-linked-etag|x-linked-size|x-repo-commit"
curl -sI "https://huggingface.co/Qwen/Qwen3-4B-GGUF/resolve/main/Qwen3-4B-Q4_K_M.gguf" \
  | grep -iE "x-linked-etag|x-linked-size|x-repo-commit"
```

`x-linked-etag` matched `lfs.oid`, `x-linked-size` matched `lfs.size`, and `x-repo-commit`
matched each repo's tree-API `sha` — two independent HF endpoints agreeing per file, with
zero bytes of either model transferred. Both `.gguf` files are single, unsharded blobs
(confirmed via the same tree listing — no `-00001-of-000NN` split). The pins are recorded
as `ModelDescriptor` statics in `Sources/LLMRuntime/LlmTierPolicy.swift` and asserted
directly in `LlmTierPolicyTests`.

**Rotating a pin:** re-run both commands above for the new revision/filename, update the
`ModelDescriptor` statics and this table, then re-run `just check`. Never hand-compute a
pin by downloading the file in CI or in this repo — the guardrail above is the point.

### Manual full-vertical test (Phase 5 — run by hand, not automated)

This is the one test that needs a real ~1.5 GB download and a real microphone, so it is
**not** part of any automated gate. Run it once per Phase-5-affecting change, on a machine
where Aide has never run before (or after deleting `~/Library/Application Support/Aide/`):

1. Build and launch: `just run`.
2. Walk onboarding through to the **tier step**. Confirm the recommended Tier (or pick the
   other one deliberately, to exercise the override path) and tap **Continue**.
3. Watch the tier step show, in order: "Checking for an already-downloaded model…" →
   "Downloading the `<tier>` speech model…" with a progress bar and a growing
   `X of Y` byte count → "Verifying the download…" → the step auto-advances.
4. Confirm the blob landed under `~/Library/Application Support/Aide/models/` (Settings →
   Data → "Reveal speech models in Finder…" also proves the reveal affordance works) and
   that `.download-state.json` is gone or shows `offset == byteSize` (no `.tmp` sibling).
5. Finish onboarding, then hold the dictation hotkey and speak a short sentence. Release —
   a real transcript of what you said should appear in the Overlay (not canned text).
6. **Resume test:** quit Aide (⌘Q) mid-download on a fresh profile (step 3, before it
   finishes), relaunch, and confirm the tier step resumes from where it left off rather
   than restarting from 0 bytes — watch the byte counter jump straight to roughly where you
   quit, not back to 0.
7. **Not-ready test:** with the download interrupted (step 6) and never resumed to
   completion, hold the hotkey anyway — the Overlay should show "Speech model isn't ready
   yet." (never a crash), matching `STTVoiceSessionDriver.modelNotReadySummary`.
8. Also run the opt-in integration check (`AIDE_RUN_STT_INTEGRATION=1 swift test --filter
   WhisperSTTEngineIntegrationTests`, spike model placed) to confirm the sample-WAV →
   transcript → Pre-Gate path is still green.
