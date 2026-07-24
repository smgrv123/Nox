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
    ]
)
