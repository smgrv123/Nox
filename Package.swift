// swift-tools-version:5.9
import PackageDescription

// Local SwiftPM package holding Aide's pure-logic modules.
//
// These build and test headlessly with `swift build` / `swift test` — no Xcode,
// no signing, no macOS permissions required. The menubar app (see project.yml /
// App/) is a separate Xcode target that depends on these products.
//
// This is the "layer 1" test surface described in docs/03-architecture.md §10.5
// and docs/05-lld.md: the deterministic core (scanner, router, registry, …) lives
// here so it can be exercised in isolation.
let package = Package(
    name: "AideModules",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AideCore", targets: ["AideCore"]),
        .library(name: "AppLifecycle", targets: ["AppLifecycle"]),
        .library(name: "DangerousCommandScanner", targets: ["DangerousCommandScanner"]),
        .library(name: "Persistence", targets: ["Persistence"]),
        .library(name: "Configuration", targets: ["Configuration"]),
        .library(name: "Overlay", targets: ["Overlay"]),
        .library(name: "Permissions", targets: ["Permissions"]),
        .library(name: "Hotkeys", targets: ["Hotkeys"]),
        .library(name: "VoiceSession", targets: ["VoiceSession"]),
        .library(name: "Onboarding", targets: ["Onboarding"]),
        // P2a · Speech-to-Text. `SpeechToText` is the pure heart (value types, the
        // `STTEngine` seam + mock); `WhisperSTTEngine` is the app-linked native shell.
        .library(name: "SpeechToText", targets: ["SpeechToText"]),
        .library(name: "WhisperSTTEngine", targets: ["WhisperSTTEngine"]),
        .library(name: "STTVoiceSession", targets: ["STTVoiceSession"]),
        // P2a/P2b · the shared, pure model-provisioning core (descriptor,
        // verification, resume math, download-state codec, models directory).
        .library(name: "ModelProvisioning", targets: ["ModelProvisioning"]),
        // P2a/P2b Phase 5 · the resumable-download effectful shell (the one allowed
        // network egress). Conforms to `ModelProvisioning.ModelDownloading`.
        .library(name: "ModelDownloader", targets: ["ModelDownloader"]),
        // P2b · LLM Runtime's pure heart (mirrors `SpeechToText`'s role for P2a):
        // `LlmTierPolicy`, `LLMEndpoint`, `SidecarController`/`SidecarState`/backoff
        // (Phase 2), and the `LLMClient` protocol + wire types + `MockLLMClient`
        // (Phase 3). Idle-unload arrives in Phase 6.
        .library(name: "LLMRuntime", targets: ["LLMRuntime"]),
        // P2b Phase 3 · the real `LLMClient` conformer: a `URLSession`-based OpenAI-
        // compatible HTTP client. A sibling module to `LLMRuntime` (not inside it, not
        // inside App/) for the same reason `ModelDownloader` sits beside
        // `ModelProvisioning` rather than inside it — its own logic (request building,
        // JSON/SSE parsing) is genuinely unit-testable headlessly against a `URLProtocol`
        // stub, so it stays in the fast `swift test` gate instead of being opt-in-only.
        .library(name: "InferenceClient", targets: ["InferenceClient"]),
    ],
    targets: [
        .target(name: "AideCore"),
        // Pure app-lifecycle decisions (single-instance today; sleep/wake later).
        // No AppKit — the effectful shell lives in App/AppCoordinator.swift.
        .target(name: "AppLifecycle"),
        .target(
            name: "DangerousCommandScanner",
            dependencies: ["AideCore"]
        ),
        // Storage tree + atomic writes + plain-text/JSONL logging (docs/05-lld.md
        // §2.6–2.7). Pure path/format logic + I/O against an injected root URL, so
        // the app never touches the real Application Support tree in tests.
        .target(name: "Persistence"),
        // Schema-versioned settings.json: model + load/save + forward-migration
        // (docs/05-lld.md §2.5). The model decode + migration are pure (testable from
        // raw Data); the load/save façade layers on Persistence's AtomicFileWriter.
        .target(
            name: "Configuration",
            dependencies: ["Persistence"]
        ),
        // Pure Overlay state machine (docs/04-hld.md §13.1): Hidden ↔ Listening ↔
        // Processing ↔ ShowingResult / PromptBack / ConfirmBack, with illegal
        // transitions guarded. No UI/I/O — the non-activating NSPanel that renders it
        // is the thin shell in App/OverlayPanel.swift.
        .target(name: "Overlay"),
        // Prompt-free permission status detection (docs/05-lld.md §8): status → fix-it
        // hint + System Settings deep-link, and the per-permission graceful-degradation
        // map. Pure Foundation-only logic; the effectful TCC queries are a thin shell in
        // the app target (App/SystemPermissionReader.swift).
        .target(name: "Permissions"),
        // Pure hotkey binding logic (docs/05-lld.md §2.5, §8, §10): maps the
        // `Settings.hotkeys` bindings to internal chords and decides which semantic
        // hotkey (command vs dictation) a raw key event is, and whether it is a
        // push-to-talk down or up. No CGEventTap here — the tap install is the thin
        // OS-bound shell in App/HotkeyManager.swift; this deep module is unit-tested
        // headlessly from injected (keyCode, flags, phase) triples.
        .target(
            name: "Hotkeys",
            dependencies: ["Configuration"]
        ),
        // Phase 6's marquee orchestration (docs/04-hld.md §13, docs/05-lld.md §10):
        // wires Phase 5's hotkey to Phase 4's Overlay through the `AideCore`
        // `VoiceSessionDriver` seam. `MockVoiceSessionDriver` is P1's conformer — a
        // real STT/routing engine (P2/P4) swaps in later with no change to
        // `VoiceSessionCoordinator` or anything upstream of it. Pure orchestration:
        // every effect (the Overlay sink, the audio cue, the auto-hide timer) is
        // injected, so it's unit-tested headlessly with fakes, no real delays.
        .target(
            name: "VoiceSession",
            dependencies: ["AideCore", "Overlay", "Hotkeys"]
        ),
        // Phase 10's first-run flow coordinator (docs/04-hld.md §14, LLD §8; User
        // Stories 16–24): a pure ordered step machine over welcome → tier confirm →
        // one step per `Permission` → the one-time network-utilities disclosure →
        // hotkey setup → guided first success → the graceful-degradation summary.
        // Depends only on `Permissions` (for `Permission`/`PermissionStatus`) and
        // `AideCore` — no AppKit, no Configuration; the App layer bridges this
        // module's pure state to/from `Configuration.Settings` (specs/P1
        // §"Onboarding").
        .target(
            name: "Onboarding",
            dependencies: ["AideCore", "Permissions"]
        ),
        // P2a · Speech-to-Text — the pure, headless heart (docs/05-lld.md §3.2, §4.1):
        // the `Transcription`/`Segment`/`LanguageHint` value types, the `STTEngine`
        // seam, `MockSTTEngine`, `SegmentPreGate`, and (later phases) `SttTierPolicy`,
        // `PCMRingBuffer`. Links NO native binary — whisper.cpp stays out of this
        // module and out of the fast `swift test` gate (the P1 `CGEventTap` precedent).
        // Depends only on `AideCore` for the shared `VoiceSessionMode` (command = strict /
        // dictation = lenient) the Pre-Gate is parameterized by — the canonical vocabulary,
        // not a parallel enum.
        .target(
            name: "SpeechToText",
            dependencies: ["AideCore", "ModelProvisioning"]
        ),
        // P2a/P2b · pure, headless model provisioning (docs/05-lld.md §2.7): the
        // `ModelDescriptor` value type, `ModelVerification` (SHA-256 + size, scanner-
        // serious), `ResumePlan` (resumable-download math), the `DownloadState` codec,
        // and `ModelsDirectory` (user-discoverable path resolution). No network, no
        // whisper — only I/O against injected file URLs. Reuses `Persistence`'s
        // `AtomicFileWriter` for the atomic `.download-state.json` mutation contract.
        // Shared with P2b's LLM runtime, so it depends on NO STT/LLM specifics.
        .target(
            name: "ModelProvisioning",
            dependencies: ["Persistence"]
        ),
        // whisper.cpp as a prebuilt, SHA-256-pinned xcframework (locked native-binary
        // decision; docs/native-deps.md). SwiftPM downloads + verifies it against the
        // checksum below — the only pin that gates the native surface. Consumed solely
        // by `WhisperSTTEngine`; never by the pure `SpeechToText` module.
        .binaryTarget(
            name: "whisper",
            url: "https://github.com/ggml-org/whisper.cpp/releases/download/v1.9.2/whisper-v1.9.2-xcframework.zip",
            checksum: "af74fed13ea7f2d5ca2a39d9f58ec177713fafd7cab63aef4e27b79f3ceca80b"
        ),
        // The effectful C-bridge conformer of `STTEngine` (specs/P2a §"Effectful
        // shells"): links the whisper xcframework and runs the real in-process decode.
        // An **app-linked** target (the App/ Xcode target depends on it via project.yml),
        // kept out of the pure module. Its only test is the opt-in, env-gated headless
        // integration check (`WhisperSTTEngineTests`), which skips without a placed model.
        .target(
            name: "WhisperSTTEngine",
            dependencies: ["SpeechToText", "whisper"]
        ),
        // P2a · the real `VoiceSessionDriver` conformer (specs/P2a §"Effectful shells"):
        // orchestrates capture → decode → Pre-Gate on `begin`/`end`. Depends only on the
        // `STTEngine` + `AudioCaptureBuffer` protocols (SpeechToText) and `AideCore`'s
        // seam — NEVER the concrete `WhisperSTTEngine` or the AVAudioEngine tap — so its
        // orchestration is unit-tested headlessly with `MockSTTEngine` + a fake capture.
        // The native engine + mic shell are injected by the App layer in production.
        .target(
            name: "STTVoiceSession",
            dependencies: ["AideCore", "SpeechToText"]
        ),
        // P2a/P2b Phase 5 · the resumable ranged-HTTP-GET shell (specs/P2a
        // §"Effectful shells"; docs/05-lld.md §2.7): the ONE allowed network egress.
        // Conforms to `ModelProvisioning.ModelDownloading` — streams to disk, hashes
        // as it streams, updates `.download-state.json` atomically, resumes from the
        // recorded offset. Kept out of `ModelProvisioning` so that module stays free
        // of `URLSession`/networking; tested headlessly against a `URLProtocol` stub
        // (no real network, no production model).
        .target(
            name: "ModelDownloader",
            dependencies: ["ModelProvisioning"]
        ),
        // P2b Phase 4 · the pure LLM-runtime heart, playing the role `SpeechToText`
        // played for P2a: `LlmTierPolicy` (Tier → Qwen `ModelDescriptor`) today; the
        // `LLMClient`/`SidecarController` seams, backoff schedule, and idle-unload state
        // machine arrive in later phases. Depends only on `ModelProvisioning` for the
        // shared `Tier` type and `ModelDescriptor` — never another pillar's concrete type.
        .target(
            name: "LLMRuntime",
            dependencies: ["ModelProvisioning"]
        ),
        // P2b Phase 3 · the real `LLMClient` conformer (specs/P2b-llm-runtime.md
        // §"Effectful shells"; see `LLMRuntime`'s product comment above for why this is a
        // sibling module rather than living in `App/`). `URLSession`/Foundation only — no
        // new logic dependencies (PRD "No new logic dependencies").
        .target(
            name: "InferenceClient",
            dependencies: ["LLMRuntime"]
        ),
        .testTarget(
            name: "AppLifecycleTests",
            dependencies: ["AppLifecycle"]
        ),
        .testTarget(
            name: "DangerousCommandScannerTests",
            dependencies: ["DangerousCommandScanner"]
        ),
        .testTarget(
            name: "PersistenceTests",
            dependencies: ["Persistence"]
        ),
        .testTarget(
            name: "ConfigurationTests",
            dependencies: ["Configuration"]
        ),
        .testTarget(
            name: "OverlayTests",
            dependencies: ["Overlay"]
        ),
        .testTarget(
            name: "PermissionsTests",
            dependencies: ["Permissions"]
        ),
        .testTarget(
            name: "HotkeysTests",
            dependencies: ["Hotkeys"]
        ),
        .testTarget(
            name: "VoiceSessionTests",
            dependencies: ["VoiceSession", "AideCore", "Overlay", "Hotkeys"]
        ),
        .testTarget(
            name: "OnboardingTests",
            dependencies: ["Onboarding", "Permissions"]
        ),
        // Pure, headless unit suite for the STT value types + mock (no native binary).
        // Depends on `ModelProvisioning` too: `SttTierPolicy` maps a Tier to a
        // `ModelDescriptor`, so its tests assert against the descriptor type.
        .testTarget(
            name: "SpeechToTextTests",
            dependencies: ["SpeechToText", "AideCore", "ModelProvisioning"]
        ),
        // Pure, headless unit suite for the model-provisioning core (no network):
        // verification over fixture bytes, resume math, codec round-trip + atomic
        // write, and path resolution against an injected temp root.
        .testTarget(
            name: "ModelProvisioningTests",
            dependencies: ["ModelProvisioning", "Persistence"]
        ),
        // Opt-in headless integration check for the real whisper decode: a committed
        // sample WAV → `WhisperSTTEngine` → assert the transcript + populated per-segment
        // probability fields. Gated by AIDE_RUN_STT_INTEGRATION=1 + a manually-placed
        // model, so it skips gracefully on the normal gate (specs/P2a §"Testing").
        .testTarget(
            name: "WhisperSTTEngineTests",
            dependencies: ["WhisperSTTEngine", "SpeechToText", "AideCore"],
            resources: [.copy("Fixtures/jfk.wav")]
        ),
        // Headless orchestration suite for the real driver: injected `MockSTTEngine` + a
        // fake `AudioCaptureBuffer` + the real `SegmentPreGate` prove pass → transcript +
        // result, fail → re-ask, and cancel → suppressed — no mic, no native binary.
        .testTarget(
            name: "STTVoiceSessionTests",
            dependencies: ["STTVoiceSession", "SpeechToText", "AideCore"]
        ),
        // Headless suite for the real resumable downloader: a `URLProtocol` stub
        // stands in for the network (no local server, no real HF/network access) —
        // full download → verified; interrupted mid-stream → resume from the
        // recorded offset → completes & verifies; a byte-mismatched transfer is
        // caught by `ModelVerification`, never reported `.verified`.
        .testTarget(
            name: "ModelDownloaderTests",
            dependencies: ["ModelDownloader", "ModelProvisioning", "Persistence"]
        ),
        // Pure, headless unit suite for the LLM-runtime heart: `LlmTierPolicy`'s Tier →
        // Qwen `ModelDescriptor` mapping, the Sidecar lifecycle state machine + backoff
        // (Phase 2), and the `LLMClient` wire types + `MockLLMClient` (Phase 3).
        .testTarget(
            name: "LLMRuntimeTests",
            dependencies: ["LLMRuntime", "ModelProvisioning"]
        ),
        // Headless suite for the real `InferenceClient`: a `URLProtocol` stub stands in
        // for the loopback Sidecar (no real process, no real network — mirrors
        // `ModelDownloaderTests`) — request building (grammar/logprobs/messages), both
        // non-streamed and SSE-streamed response parsing, and aligned byte-range logprobs.
        .testTarget(
            name: "InferenceClientTests",
            dependencies: ["InferenceClient", "LLMRuntime"]
        ),
    ]
)
