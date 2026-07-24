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
        .library(name: "DangerousCommandScanner", targets: ["DangerousCommandScanner"]),
    ],
    targets: [
        .target(name: "AideCore"),
        .target(
            name: "DangerousCommandScanner",
            dependencies: ["AideCore"]
        ),
        .testTarget(
            name: "DangerousCommandScannerTests",
            dependencies: ["DangerousCommandScanner"]
        ),
    ]
)
