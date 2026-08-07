# Aide task runner (the `package.json scripts` analog).
# Run `just` or `just --list` to see recipes. Run one with `just <name>`.

set shell := ["bash", "-uc"]

_dirs := "Sources App Tests"

# Built .app path (from `app`'s -derivedDataPath) and stable signing identity.
_app := ".build/xcode/Build/Products/Debug/Aide.app"
_sign_identity := "Aide Local Dev"

# List available recipes (default).
default:
    @just --list

# ── Format (Prettier analog: swift-format) ─────────────────────────────
# Format all Swift sources in place.
format:
    swift format format --in-place --parallel --recursive {{_dirs}}

# Check formatting without writing (used by CI + the pre-commit hook).
format-check:
    swift format lint --strict --parallel --recursive {{_dirs}}

# ── Lint (ESLint analog: SwiftLint) ────────────────────────────────────
# Report lint issues.
lint:
    swiftlint lint --quiet

# Autofix lint issues where possible.
lint-fix:
    swiftlint lint --fix --quiet

# ── Build & test ───────────────────────────────────────────────────────
# Type-check / compile the modules (the `tsc --noEmit` analog).
typecheck:
    swift build

# Build the SwiftPM modules.
build:
    swift build

# Run the module tests.
test:
    swift test

# ── Xcode app target ───────────────────────────────────────────────────
# Regenerate Aide.xcodeproj from project.yml.
gen:
    xcodegen generate

# Compile the .app without signing (verifies the app target builds).
app: gen
    xcodebuild -project Aide.xcodeproj -scheme Aide -destination 'platform=macOS' \
        -derivedDataPath .build/xcode CODE_SIGNING_ALLOWED=NO build | \
        grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" || true

# ── Run (signed local dev) ─────────────────────────────────────────────
# A stable named identity keeps the same code identity across rebuilds, so
# macOS TCC grants (e.g. Accessibility for the global hotkey) persist.
# Override the identity name with AIDE_SIGN_IDENTITY.
# Build, sign with a stable identity (else ad-hoc), and launch the app.
run: app
    #!/usr/bin/env bash
    set -euo pipefail
    app="{{_app}}"
    identity="${AIDE_SIGN_IDENTITY:-{{_sign_identity}}}"
    if security find-identity -p codesigning | grep -qF "$identity"; then
        echo "Signing '$app' with '$identity' (grants persist across rebuilds)."
        codesign --force --deep --sign "$identity" "$app"
    else
        echo "note: '$identity' identity not found — signing ad-hoc; Accessibility grants won't persist until you run 'just setup-signing'."
        codesign --force --deep --sign - "$app"
    fi
    open "$app"

# Verify (or explain how to create) the stable local signing identity.
setup-signing:
    #!/usr/bin/env bash
    set -euo pipefail
    identity="${AIDE_SIGN_IDENTITY:-{{_sign_identity}}}"
    if security find-identity -p codesigning | grep -qF "$identity"; then
        echo "✅ '$identity' signing identity present — 'just run' will use it (self-signed certs are untrusted but sign fine); Accessibility grants will persist across rebuilds."
    else
        echo "No '$identity' signing identity found. Create it once via Keychain Access:"
        echo "  1. Keychain Access → menu → Certificate Assistant → Create a Certificate…"
        echo "  2. Name:             $identity"
        echo "  3. Identity Type:    Self Signed Root"
        echo "  4. Certificate Type: Code Signing"
        echo "  5. Click Create, then re-run 'just setup-signing' to confirm."
    fi

# ── Aggregate gates ────────────────────────────────────────────────────
# Everything a CI / pre-push gate runs: format check, lint, build, test.
check: format-check lint build test

# Auto-fix then build+test (fast local loop).
fix: format lint-fix build test
