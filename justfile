# Aide task runner (the `package.json scripts` analog).
# Run `just` or `just --list` to see recipes. Run one with `just <name>`.

set shell := ["bash", "-uc"]

_dirs := "Sources App Tests"

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

# ── Aggregate gates ────────────────────────────────────────────────────
# Everything a CI / pre-push gate runs: format check, lint, build, test.
check: format-check lint build test

# Auto-fix then build+test (fast local loop).
fix: format lint-fix build test
