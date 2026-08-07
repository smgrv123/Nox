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
    ]
)
