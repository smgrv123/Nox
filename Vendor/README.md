# Vendor

Third-party inference components. **Nothing here is committed as a binary** (see `.gitignore`).

## Planned contents

| Path | What | How it gets here |
|---|---|---|
| `Vendor/whisper.cpp/` | whisper.cpp source, integrated **in-process** via SwiftPM | git submodule / pinned checkout (locked decision #3) |
| `Vendor/bin/llama-server` | Prebuilt `llama-server` binary — the **sole sidecar** | Downloaded/built at a pinned version, bundled into the `.app` |
| `Vendor/models/` | Downloaded GGUF/GGML models (Whisper + Qwen3) | Fetched at first launch from pinned Hugging Face commit SHAs with SHA-256 verification (locked decision #8). Also gitignored. |

Models are **not** bundled in the app (PRD §2) — they download on first run with a progress UI.
See `docs/03-architecture.md` §9 (Deployment & Packaging) and `docs/04-hld.md` §4 (LLM Runtime & Sidecar Management).
