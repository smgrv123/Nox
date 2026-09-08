# PRD — P5b · Personalization Dictionary

> Second of the two verticals **P5 · Dictation** (see [`docs/07-implementation-pillars.md`](../docs/07-implementation-pillars.md)):
> **P5a · Dictation Core** (already spec'd) and **P5b · Personalization Dictionary** (this doc).
> Grounded in [`docs/04-hld.md`](../docs/04-hld.md) §9.3, §15.2 and [`docs/05-lld.md`](../docs/05-lld.md) §2.3, §4.5, §6.3.
> Status: draft spec · planned in [`plans/P5b-personalization-dictionary.md`](../plans/P5b-personalization-dictionary.md).
> **Depends on P5a** for the cleanup-prompt substitution slot and on P4 for the skill registry / GBNF / executor path ("correct that" is a Command Mode skill).

## Why this is its own vertical

The dictionary is a bounded, explicit-only store with its own schema, promotion policy, MRU eviction, and two consuming prompts. It is demoable on its own once P5a's driver exposes the `initialPrompt` and substitution-list providers (no-ops in P5a). Shipping it inside P5a would hide a second "done" behind insertion work.

**Explicitness override.** Same as P5a: other agents implement this. Name files, signatures, constants, registration steps, and tests. Do not strip them for template purity.

## Problem Statement

Whisper will keep mishearing the user's name, team jargon, and tool names (`Kubernetes` as "cooper nettie's"). Cleanup can only fix what it is told. Today there is **no** place to teach Aide a correction, **no** Whisper bias prompt from personal vocabulary (Command Mode only injects a 50-name app catalog — explicitly *not* this feature, see `CommandModeDriver+Pipeline.swift` `appNameBiasPrompt`), and **no** substitution list in the §6.3 cleanup prompt.

Without an explicit, bounded, local dictionary, every session re-learns nothing, and the only workaround is the user re-speaking until Whisper lucks out.

## Solution

A **Personalization Dictionary** that is the single source of truth, **explicit-only in v1**, **no model training**:

- One document at `StorageLayout.dictionaryFile` (`dictionary.json`) — the slot **already exists**, commented "owned by P5". Schema LLD §2.3, `schema_version: 1`, `hard_cap: 500`.
- Population via Command Mode skill `correct_that`: speak "correct that: cooper nettie's should be Kubernetes" → entry created, `source: explicit`, `promoted: true` immediately (LLD §4.5B).
- Optional Settings list: view / edit / delete / manual add (manual add **is** the custom-vocabulary feature).
- **Whisper bias prompt (LLD §4.5D):** promoted `correct_term`s ranked recency×frequency, tokenized with the **real Whisper tokenizer** (locked: not a 4-chars-per-token approximation), greedy fill up to **200 tokens** (PROVISIONAL; Whisper cap 224 minus margin). Merged with P4's existing app-name bias and fed to **both** `CommandModeDriver` and `DictationDriver` `initialPrompt`.
- **Cleanup substitutions (LLD §4.5E):** top **40** (PROVISIONAL) `mishearing → correct` pairs, same ranking, injected into P5a's `CleanupPromptBuilder` slot.
- MRU eviction when `entries.count > hard_cap`. Explicit-source entries evicted last (LLD §4.5C assumption, now locked).
- Raw before/after correction text is discarded after pair extraction — never persisted.

## User Stories

### Teaching Aide
1. As a user, I want to say "correct that: X should be Y" in Command Mode and have Y enter my dictionary immediately, so that I do not edit a JSON file.
2. As a user, I want repeating the same correction to add another mishearing on the same canonical term (case-insensitive), so that I don't get duplicate entries for "Kubernetes" / "kubernetes".
3. As a user, I want to add a term by hand in Settings, so that I can preload names before dictating.
4. As a user, I want to edit or delete an entry, so that a bad correction is not permanent.
5. As a user, I want the dictionary kept **on this Mac only**, never uploaded.

### Consumption
6. As a user, I want promoted spellings to bias Whisper (dictation **and** command), so that "Kubernetes" is more likely on the next utterance.
7. As a user, I want known mishearings substituted during dictation cleanup, so that a residual mishearing still gets fixed in the inserted text.
8. As a user, I want those prompts **bounded**, so that a large dictionary cannot blow Whisper's 224-token cap or the cleanup context.
9. As a user, I want Command Mode's app-name bias to **share the same prompt slot** rather than being replaced, so that "open Ghostty" does not regress.

### Bounds and wipe
10. As a user, I want the oldest unused entries dropped after 500, with names I explicitly taught kept longer than auto-extracted ones.
11. As a user, I want "Wipe all history" to **leave** `dictionary.json` unless I separately choose to wipe it, so that vocabulary is configuration, not a transcript trail.

### Developer-facing
12. As a developer, I want store / promotion / eviction / budgeting as pure headless modules with a fake `TokenCounting`.
13. As a developer, I want `whisper_tokenize` behind that protocol so production budgeting cannot silently overflow the cap.
14. As a developer, I want `correct_that` to be a normal P4 builtin (manifest + GBNF alternative + executor), not a special Overlay path.

## Implementation Decisions

**Vertical boundary.** P5b owns `dictionary.json`, promotion/MRU/budgeting, the `correct_that` skill, Settings dictionary pane, and wiring providers into P5a's slots + Command Mode's `initialPrompt`. It does not own insertion, tone presets, or the cleanup LLM call (P5a).

**Locked this session:**

| Decision | Lock |
|---|---|
| Token counting | Real Whisper tokenizer via `whisper_tokenize` from the already-vendored whisper.cpp xcframework (`WhisperSTTEngine` / C bridge). Protocol `TokenCounting` so budgeting is tested against a fake counter. **Rejected:** ~4-chars-per-token approximation (can overflow 224). |
| v1 population | Explicit only (`correct_that` + Settings manual add). Auto edit-detection is architected in types (`source: auto`, `PROMOTE_MIN = 2`) but **no code path creates `auto` entries**. |
| Merge with app-name bias | Shared `BiasPromptBuilding` used by both drivers. Dictionary terms first (ranked), then P4's alphabetical app-name list in leftover budget (still cap 50 names, skip system utilities). |
| Branch | Same `feat/p5a-dictation-core` as P5a |

**Module `Sources/Personalization/`** (new SwiftPM). Depends on `Persistence` (AtomicFileWriter, StorageLayout). Must not import AppKit, whisper, or `InferenceClient`.

| Type | Role |
|---|---|
| `DictionaryDocument` / `DictionaryEntry` | LLD §2.3 Codable. `id` is a new ULID/UUID string (`e_` prefix optional). `source` enum `explicit` \| `auto`. Dates ISO-8601. |
| `TermPair` | `mishearing` + `correctTerm` |
| `TermPairExtractor` | Explicit path: trim, reject empty, reject identical pair. Auto path: **stub that is uncalled** (do not call the LLM to diff in v1). |
| `PromotionPolicy` | `explicit` → `promoted = true`; `auto` → `promoted` iff `occurrenceCount >= promoteMin` (inject `2`). |
| `MRUEviction` | If count > cap, sort `lastUsedAt` ascending; evict non-explicit first, then oldest explicit, until within cap. |
| `TokenCounting` | `func tokenCount(_ text: String) -> Int` |
| `BiasPromptBudget` | Rank `score = occurrenceCount * recencyWeight(lastUsedAt, now, halfLifeDays: 14)`; greedy comma-join `correct_term`s stopping **before** exceeding `tokenBudget` (200). |
| `SubstitutionListBuilder` | Top N=40 pairs as `"mishearing -> correct"` lines for §6.3. |
| `BiasPromptBuilding` | Dictionary budget + leftover + extra phrases (app names). |
| `DictionaryStore` | `actor`. Load/save `dictionary.json` atomically. `record(pairs:source:now:)`, `entries`, `remove(id:)`, `upsert(entry:)`. Invalidate a generation counter so bias cache recomputes. |

**Whisper tokenizer shell (not in Personalization):** `Sources/WhisperSTTEngine/WhisperTokenCounter.swift` (name flexible) conforming to `TokenCounting`, calling `whisper_tokenize` on the loaded context **or** the C API that tokenizes without a full decode. If the xcframework only tokenizes with a loaded model, it is acceptable to require `ensureLoaded()`; tests of `BiasPromptBudget` never call this type. **If `whisper_tokenize` is not in the v1.9.2 xcframework ABI**, stop and report — do **not** silently fall back to character approximation. (Implementer: check `whisper.h` in the binary target / module map.)

**`correct_that` skill (cuts into P4):**

- Add to `Sources/BuiltinSkills/BuiltinManifestCatalog.swift` `all`.
- `id: "correct_that"`
- `kind: .builtin`
- `risk_tier: low`
- `parameters`: required `mishearing` (string, 1–200), `correct_term` (string, 1–200)
- `utterance_examples`: `["correct that cooper nettie's should be Kubernetes", "correct that sam rit should be Sumrit"]`
- `BuiltinSkillRouter.pureResult` new case (pure: it talks to an injected `DictionaryRecording` protocol, **not** the filesystem directly, so tests don't touch disk).
- App composition root injects `DictionaryStore`.
- GBNF updates automatically when the registry includes the new manifest — still add a registry/grammar test that `correct_that` is an alternative.
- Router prompt catalog will list it; add an utterance example so the LLM actually routes here.

**Command Mode `initialPrompt` wiring.** Today `CommandModeDriver+Pipeline.swift` computes app names inline. Change `CommandModeDriver` to take

```
var makeInitialPrompt: @Sendable () async -> String?
```

defaulting to today's `appNameBiasPrompt` **only if** the new parameter is omitted during a transition. P5b Phase 3's composition root supplies the merger. `DictationDriver`'s existing no-op slot (P5a) gets the same merger. Do not have `Personalization` import `CommandMode`.

**Settings pane.** `App/Settings/DictionaryPane.swift` appended to `SettingsRootView.panes`. Uses `DictionaryStore` via `AppCoordinator`. Wipe UI: do **not** add dictionary to default `HistoryWipe` scope. Optional "Reset dictionary" on this pane is in scope (separate button, confirm, deletes `dictionary.json` and starts empty).

**Constants (PROVISIONAL, injected — never asserted as literals in tests except via the injected struct):**

| Name | Value |
|---|---|
| `hardCap` | 500 |
| `tokenBudget` | 200 |
| `whisperPromptCap` | 224 (documentation / assert leftover ≥ 0) |
| `substitutionTopN` | 40 |
| `recencyHalfLifeDays` | 14 |
| `promoteMin` | 2 |
| `appNameCap` | 50 (keep P4 behavior) |

**Storage.** `AtomicFileWriter` already in Persistence. `DictionaryStore` writes `layout.dictionaryFile`. Missing file → empty document with `schema_version: 1`, `hard_cap: 500`, `entries: []`.

## Testing Decisions

TDD, public-interface only, `DangerousCommandScanner` pattern.

- **Codec** — fixture JSON from LLD §2.3 round-trips; unknown `source` fails closed (reject entry or fail decode — pick reject-entry-on-load, never crash the app).
- **TermPairExtractor** — trim; empty rejected; case-insensitive merge keys on `correct_term`.
- **PromotionPolicy** — explicit always promoted; auto below min not consumed; auto at min promoted.
- **MRUEviction** — 501st insert evicts oldest auto before any explicit; empty lastUsedAt treated as oldest.
- **BiasPromptBudget** — fake counter that returns `ceil(chars/4)` *in tests only*; adding a term that would exceed budget is skipped; order is score descending.
- **SubstitutionListBuilder** — N cap; only promoted entries; format stable.
- **DictionaryStore** — atomic write (crash-mid-write fixture if AtomicFileWriter already guarantees this, don't re-test the writer); record explicit pair visible to `biasTerms()`.
- **correct_that skill** — parameters extracted; recorder called; bad/missing params → `SkillExecutionError`.
- **Grammar** — `correct_that` literal present in `routerGrammar()`.
- **Wipe** — existing `HistoryWipeTests` still assert `dictionary.json` is out of default scope; add a pane-level reset test at the store layer (`replaceAll([])`).

**Not in headless suite:** Settings list UI, real `whisper_tokenize` (optional opt-in if a model is present, like `WhisperSTTEngineTests`).

**Per-phase gate:** same as P5a (`just check` + `just app` + 0 lint warnings). Phase 2+ touch `App/` and `BuiltinSkills` — `just app` is mandatory.

## Out of Scope

- Auto-population from "the user edited the inserted text" (architected only).
- Character-approximation tokenizer.
- Training / fine-tuning / uploading the dictionary.
- Changing P5a's insertion or tone machinery except the two provider slots.
- Adding dictionary to default history wipe.
- Cloud sync.

## Further Notes

- **P4 dependency is explicit:** Phase 2 of this plan edits `BuiltinManifestCatalog`, `BuiltinSkillRouter`, SkillManifest fixtures if any, and the composition root. That is intended, not scope creep.
- **"Done":** say "correct that: cooper nettie's should be Kubernetes" → Settings shows the entry → next dictation bias/cleanup includes it → 500+1 explicit-and-auto mix evicts auto first.
- Input to [`plans/P5b-personalization-dictionary.md`](../plans/P5b-personalization-dictionary.md). Execute **after** P5a Phase 3 at minimum for substitution injection (P5b Phase 4); P5b Phases 1–2 can proceed once P5a has landed far enough to share the branch, but substitution wiring waits on `CleanupPromptBuilder`.
