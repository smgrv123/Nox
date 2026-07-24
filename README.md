# Aide

A local-first macOS voice assistant. Push-to-talk voice commands, tone-aware
dictation, and screen Q&A — with **all inference running locally**. See
[`docs/`](docs/) for the full spec (start with
[`01-problem-to-solve.md`](docs/01-problem-to-solve.md)).

> Status: **v0.1.0 — project skeleton / tracer bullet.** Menubar app shell +
> global hotkey tap + the deterministic core's first module (Dangerous-Command
> Scanner) with tests.

## Requirements

- Apple Silicon Mac, macOS 14+
- Xcode 26+ (`xcode-select --install` for the CLI tools)
- [XcodeGen](https://github.com/yonatanbetavier/XcodeGen): `brew install xcodegen`

## Layout

```
Aide/
├── project.yml          # XcodeGen spec (source of truth; .xcodeproj is generated + gitignored)
├── Package.swift        # Local SwiftPM package: the pure-logic modules
├── Sources/             #   AideCore, DangerousCommandScanner, …
├── Tests/               #   headless unit tests (swift test)
├── App/                 # The menubar app target (SwiftUI, hotkey, sidecar mgmt)
├── Vendor/              # whisper.cpp + bundled llama-server + models (not committed)
└── docs/                # HLD, LLD, architecture, walk-throughs, glossary, problem-to-solve
```

The **deterministic core** (scanner, router, registry, …) lives in `Sources/` as a
SwiftPM package so it builds and tests **headlessly — no Xcode, no signing, no
permissions**. The **app shell** is a thin Xcode target generated from `project.yml`.

## Develop

Primary editor: **VS Code** (install the Swift extension) for writing code and the
non-Swift assets. **Xcode** is the build/run/sign/debug harness for the actual app.

### Test the core (fast, headless)

```sh
swift build
swift test
```

### Build & run the app

```sh
xcodegen generate          # regenerate Aide.xcodeproj from project.yml
open Aide.xcodeproj        # then set your Team under Signing & Capabilities, ⌘R
```

On first run, grant **Accessibility** (System Settings ▸ Privacy & Security ▸
Accessibility) so the global hotkey tap can install — the menubar menu links
straight to the pane. Then hold **F13** and watch the menubar status flip to
"🎙️ Listening…" (placeholder Push-to-Talk key for the tracer bullet).

## Testing layers

1. **Unit (`swift test`)** — deterministic core, headless. Most test value lives here.
2. **Integration** — whisper transcription on sample audio, `llama-server` round-trips, model-download checksums.
3. **Manual (Xcode ⌘R)** — permission-gated behavior: hotkeys, AX text insertion, screenshot/OCR, the overlay.
