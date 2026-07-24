# Aide

Local-first macOS voice assistant — a Swift/SwiftUI **menubar app**. All inference runs
locally (whisper.cpp STT + a llama-server sidecar); the only network egress is one-time
model downloads and explicit, user-visible BYOK cloud escalation. See `docs/` for the spec.

## Commands

Task runner is [`just`](https://github.com/casey/just) (the `package.json scripts` analog). Run `just` to list.

```bash
just format        # swift-format --in-place        (Prettier analog)
just format-check  # swift-format --lint (no writes; CI + pre-commit)
just lint          # SwiftLint                      (ESLint analog)
just lint-fix      # SwiftLint --fix                (≈ lint:fix)
just typecheck     # swift build                    (tsc --noEmit analog)
just test          # swift test                     (headless module tests)
just gen           # xcodegen generate              (regenerate Aide.xcodeproj)
just app           # build the .app (signing-free compile check)
just check         # format-check + lint + build + test  (the full gate)
just fix           # format + lint-fix + build + test    (fast local loop)
```

Pre-commit hook (`.githooks/pre-commit`, wired via `core.hooksPath`) auto-fixes staged
`.swift` files (swift-format + swiftlint --fix, re-stage) and blocks only on unfixable lint.

## Key Rules

- **Pillars, not a monolith:** work happens per pillar (P1–P7) — see `docs/07-implementation-pillars.md`. Each pillar has a PRD in `specs/` and a phased plan in `plans/`.
- **Formatting is owned by swift-format** (`.swift-format`); **SwiftLint** (`.swiftlint.yml`) owns lint/correctness only. Don't fight them — run `just fix`. Change the config deliberately rather than sprinkling inline `swiftlint:disable`.
- **Deep modules, tested in isolation:** pure logic lives in SwiftPM modules under `Sources/` and is unit-tested headlessly (`swift test`); the app target (`App/`) is a thin shell. `AideCore` holds shared types + the interface **protocols** (the seams).
- **TDD for deep modules:** write the failing test first — the `DangerousCommandScanner` suite is the pattern — then implement.
- **The Dangerous-Command Scanner is the safety boundary:** never weaken a test to make it pass. False positives are acceptable; false negatives are not.
- **Independence via seams:** a pillar depends on `AideCore` protocols + mocks, never another pillar's concrete implementation. Real implementations swap in with no change to consumers.
- **The Xcode project is generated:** edit `project.yml`, then `just gen`. Never hand-edit `Aide.xcodeproj` (gitignored).
- **Local-first by default:** honor the privacy invariants in `docs/03-architecture.md` §10.1 — nothing leaves the machine implicitly.
- **Phased execution follows `/execute-plan`:** independent phases run in parallel batches, dependent phases in order (per the plan's dependency analysis); pause for user review after each batch.

## Cross-Cutting Docs

Read these **only when the scope of work requires it** — not for small fixes.

- `docs/07-implementation-pillars.md` — the pillar map. Read before starting any pillar.
- `docs/01-problem-to-solve.md` · `docs/02-glossary.md` — the "why" + canonical terms. Read for terminology.
- `docs/03-architecture.md` — MUST read before cross-cutting concerns, new processes, or data flows.
- `docs/04-hld.md` — MUST read before building a subsystem (per-subsystem design).
- `docs/05-lld.md` — MUST read for concrete schemas, algorithms, interfaces, state machines.
- `docs/06-walkthrough.md` — end-to-end scenario traces.
- `specs/<pillar>.md` + `plans/<pillar>.md` — the PRD + phased plan for the pillar in progress.

## Maintenance

- When a phase completes, update its status in `docs/07-implementation-pillars.md` and check off the acceptance criteria in the plan.
- When adding a module, register it in `Package.swift` and (if the app depends on it) `project.yml`, then `just gen`.
- Keep `.swift-format` / `.swiftlint.yml` authoritative — if a rule fights you often, change the config, don't work around it per-file.
