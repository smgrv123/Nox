# Vendor

Third-party inference components. **Nothing here is committed as a binary** (see `.gitignore`).

whisper.cpp itself is never vendored here — it's a checksum-pinned SwiftPM `.binaryTarget`
that Swift Package Manager fetches straight into its own build cache (`docs/native-deps.md`).

## Contents

| Path | What | How it gets here |
|---|---|---|
| `Vendor/bin/llama-server/` | Prebuilt `llama-server` executable — the **sole sidecar** — plus the ten sibling `.dylib`s it dynamically links via `@rpath`/`@loader_path` (a **directory**, not a single file: `llama-server` cannot launch without them alongside it) | `just vendor-llama-server` — pinned version, SHA-256-verified, bundled into `Aide.app` via a Copy Files build phase (`docs/native-deps.md` § llama-server (LLM Sidecar)) |
| `Vendor/models/` | Downloaded GGUF/GGML models (Whisper + Qwen3), plus a Phase-1-only dev/smoke-test Qwen2.5-0.5B GGUF | Fetched at first launch from pinned Hugging Face commit SHAs with SHA-256 verification (locked decision #8). Also gitignored. |

Production models are **not** bundled in the app (PRD §2) — they download on first run with a progress UI.
See `docs/03-architecture.md` §9 (Deployment & Packaging) and `docs/04-hld.md` §4 (LLM Runtime & Sidecar Management).
