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

# ── Native deps (Vendor/, not committed — docs/native-deps.md) ─────────
_llama_release := "b10332"
_llama_asset := "llama-b10332-bin-macos-arm64.tar.gz"
_llama_sha256 := "2f5b9eef98f5376465cd00402ef3a68eaac1f4b11f9de0a6a59b1307255399a8"
_llama_dir := "Vendor/bin/llama-server"

# Fetch, checksum-verify, and place the pinned `llama-server` binary + its sibling
# dylibs (docs/native-deps.md § llama-server (LLM Sidecar)) at Vendor/bin/llama-server/,
# mirroring how SwiftPM auto-fetches the pinned whisper xcframework — llama-server can't
# use that mechanism (it's a spawnable executable, not a linkable binaryTarget), so this
# recipe is the equivalent build-time fetch. Idempotent: skips the download once the
# binary is present (delete the directory to force a re-fetch after rotating the pin).
vendor-llama-server:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ -x "{{_llama_dir}}/llama-server" ]; then
        echo "Vendor/bin/llama-server already present — skipping fetch (rm -rf {{_llama_dir}} to force)."
        exit 0
    fi
    url="https://github.com/ggml-org/llama.cpp/releases/download/{{_llama_release}}/{{_llama_asset}}"
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    echo "Downloading $url"
    curl -sL -o "$tmp/asset.tar.gz" "$url"
    actual=$(shasum -a 256 "$tmp/asset.tar.gz" | awk '{print $1}')
    if [ "$actual" != "{{_llama_sha256}}" ]; then
        echo "error: llama-server checksum mismatch"
        echo "  expected {{_llama_sha256}}"
        echo "  actual   $actual"
        exit 1
    fi
    tar -xzf "$tmp/asset.tar.gz" -C "$tmp"
    src="$tmp/llama-{{_llama_release}}"
    mkdir -p "{{_llama_dir}}"
    # llama-server dynamically links these via @rpath, resolved against @loader_path
    # (its own directory) — all must sit flat alongside it, not just the executable.
    for f in llama-server libllama-server-impl.dylib libllama-common.0.dylib libmtmd.0.dylib \
             libllama.0.dylib libggml.0.dylib libggml-cpu.0.dylib libggml-blas.0.dylib \
             libggml-metal.0.dylib libggml-rpc.0.dylib libggml-base.0.dylib LICENSE; do
        cp -L "$src/$f" "{{_llama_dir}}/$f"
    done
    chmod +x "{{_llama_dir}}/llama-server"
    xattr -d com.apple.quarantine "{{_llama_dir}}"/* 2>/dev/null || true
    echo "llama-server {{_llama_release}} verified and placed at {{_llama_dir}}/"

# ── Xcode app target ───────────────────────────────────────────────────
# Regenerate Aide.xcodeproj from project.yml.
gen: vendor-llama-server
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
