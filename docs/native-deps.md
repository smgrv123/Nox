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

Model blobs are large and are **not** in git (see `.gitignore`). In P2a Phase 1 the model
is placed manually; Phase 5 adds resumable, checksum-verified provisioning.

- **Location:** `~/Library/Application Support/Aide/models/`
- **Spike/test model:** `ggml-base.en.bin` (~148 MB), SHA-256
  `a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002`, from
  [`ggerganov/whisper.cpp`](https://huggingface.co/ggerganov/whisper.cpp) on Hugging Face.

### Running the opt-in STT integration check

The real-decode check (`WhisperSTTEngineTests`) is excluded from the fast unit gate. With
the model placed above:

```bash
AIDE_RUN_STT_INTEGRATION=1 swift test --filter WhisperSTTEngineIntegrationTests
```

Without the env var or the model, it `XCTSkip`s, so `just test` stays green on a machine
that has neither.
