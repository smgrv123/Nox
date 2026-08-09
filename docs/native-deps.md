# Native dependencies

Aide's only prebuilt native artifact is the whisper.cpp xcframework (P2a · Speech-to-Text).
It is **pinned by SHA-256 checksum**, never built from source, and consumed only by the
app-linked `WhisperSTTEngine` target — never by the pure `SpeechToText` module.

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
