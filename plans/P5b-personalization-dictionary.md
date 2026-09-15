# Plan: P5b · Personalization Dictionary

> Source PRD: [`specs/P5b-personalization-dictionary.md`](../specs/P5b-personalization-dictionary.md)
> Depends on: P4 (registry / GBNF / `BuiltinSkillRouter`), P5a (`DictationDriver` prompt slots, `CleanupPromptBuilder`).
> Grounded in: HLD §9.3, §15.2; LLD §2.3, §4.5, §6.3.
> Execution: same branch `feat/p5a-dictation-core`, **after P5a** (Phase 4 of this plan needs P5a Phase 3). TDD.
>
> **Explicitness override.** Same as P5a — file names, signatures, constants, tests. P5b Phase 2 **intentionally cuts into P4** (`BuiltinManifestCatalog`, `BuiltinSkillRouter`, composition root). Call that out in the commit body; do not treat it as accidental coupling.

## Architectural decisions

- **New SwiftPM module `Personalization`** at `Sources/Personalization/`, tests `Tests/PersonalizationTests/`. `Package.swift` product + target (deps: `Persistence`, `AideCore` if needed for nothing — prefer Persistence only) + testTarget. `project.yml` product `Personalization`. `just gen`.
- **Forbidden imports:** AppKit, `whisper` binary, `InferenceClient`, `CommandMode`, `Dictation` (Personalization does not depend on Dictation; the **App** and **DictationDriver** closures pull values *from* the store).
- **`StorageLayout.dictionaryFile` already exists.** Use it. Do not add a second slot.
- **Token counting (locked):** protocol `TokenCounting { func tokenCount(_ text: String) -> Int }` in `Personalization`. Production conformer in `WhisperSTTEngine` wrapping `whisper_tokenize`. If the symbol is missing from xcframework v1.9.2, **stop and report** — no char-approximation fallback.
- **v1 writes `source: explicit` only.** Keep `auto` on the enum and `PromotionPolicy` for auto, but no caller creates auto entries.
- **MRU:** evict `auto` (oldest `lastUsedAt` first) before any `explicit`. Then oldest explicit. Cap 500.
- **Bias merge:** dictionary terms first (budget 200 tokens), then up to 50 non-utility app display names in leftover tokens. Both `CommandModeDriver` and `DictationDriver` use one `makeInitialPrompt` closure from `AppCoordinator`.
- **Wipe:** default `HistoryWipe` continues to spare `dictionary.json`. Dictionary pane may offer a separate reset.
- **Per-phase gate:** `just check` + `just app` + 0 lint warnings. Same App/ vs swift-build caveat as P5a.
- **Provisional injected constants** (`Personalization.BudgetConfig`): `hardCap=500`, `tokenBudget=200`, `substitutionTopN=40`, `recencyHalfLifeDays=14`, `promoteMin=2`, `appNameCap=50`. Tests inject the config; do not hardcode 500 in assertions except `BudgetConfig.default` field tests.

---

## Phase 1: Dictionary store + schema

**User stories**: 5, 10, 12

### What to build

Codable document + actor store + promotion + MRU. Headless. No UI, no Whisper, no skill.

Files (all under `Sources/Personalization/`):

- `DictionaryEntry.swift` / `DictionaryDocument.swift` — LLD §2.3 fields. JSON keys snake_case: `schema_version`, `hard_cap`, `correct_term`, `mishearings`, `occurrence_count`, `promoted`, `source`, `created_at`, `last_used_at`.
- `TermPair.swift`, `TermPairExtractor.swift` — `extractExplicit(mishearing:correct:)` trims; throws/returns nil on empty or if equal case-insensitively.
- `PromotionPolicy.swift`
- `MRUEviction.swift` — `func evict(_ entries: [DictionaryEntry], cap: Int) -> [DictionaryEntry]`
- `DictionaryStore.swift` — `actor` with `init(fileURL: URL, writer: AtomicFileWriter.Type or injected write fn, clock: () -> Date)`. Methods: `load()`, `record(mishearing:correct:source:)`, `remove(id:)`, `upsert(_ entry:)`, `allEntries()`, `promotedEntries()`. After every mutation: promotion fields updated, MRU, atomic write. Missing file on load → empty document, no write until first mutation.

Register module.

### Named tests (`Tests/PersonalizationTests/`)

- `DictionaryCodecTests.testLLDFixtureRoundTrip` — use the Kubernetes example from LLD §2.3 (may shorten timestamps).
- `TermPairExtractorTests.testRejectsEmpty`
- `TermPairExtractorTests.testTrims`
- `PromotionPolicyTests.testExplicitIsImmediate`
- `PromotionPolicyTests.testAutoBelowMinNotPromoted`
- `MRUEvictionTests.testEvictsOldestAutoBeforeExplicit`
- `MRUEvictionTests.testCapsAtHardCap`
- `DictionaryStoreTests.testRecordExplicitPersistsAndReloads`
- `DictionaryStoreTests.testCaseInsensitiveMergeAddsMishearing`

### Acceptance criteria

- [ ] Module registered; named tests pass.
- [ ] File written at the injected URL is valid JSON with `schema_version: 1`.
- [ ] Per-phase gate green (`just app` still required after `project.yml`).

---

## Phase 2: "correct that" built-in skill

**User stories**: 1, 2, 14

### What to build

**This phase edits P4 modules.** Treat it as an intentional extension of the registry.

1. `Sources/BuiltinSkills/BuiltinManifestCatalog.swift` — append `correctThat` to `all` with:
   - `id: "correct_that"`
   - `displayName: "Correct That"`
   - description: "Remember a mishearing and the correct spelling in the personal dictionary."
   - examples as in the PRD
   - parameters required `mishearing`, `correct_term` (string minLength 1, maxLength 200)
   - `riskTier: .low`
2. `Sources/BuiltinSkills/CorrectThatSkill.swift` — `static func run(parameters: JSONValue, dictionary: any DictionaryRecording) async throws -> SkillResult`. Parse the two strings; call `dictionary.record`. Summary `"Remembered “Y” (heard as “X”)."`
3. `protocol DictionaryRecording: Sendable { func record(mishearing: String, correctTerm: String) async throws }` — live conformer is `DictionaryStore`.
4. `BuiltinSkillRouter` — `correct_that` cannot be a pure no-deps case; it needs the recorder. **Change:** add `dictionary: (any DictionaryRecording)?` to `BuiltinSkillRouter.init` (default nil). In `pureResult`/`execute`, if `skillID == "correct_that"`: guard dictionary else throw `SkillExecutionError` with message `"Dictionary isn't available."`; else run the skill. This is an initializer expansion — update every production and test call site that constructs `BuiltinSkillRouter`.
5. `App/AppCoordinator+CommandMode.swift` — construct `DictionaryStore(fileURL: storage.dictionaryFile)`, inject into the router.
6. Tests: `Tests/BuiltinSkillsTests/CorrectThatSkillTests.swift`; `Tests/SkillRegistryTests` (or CommandRouter) assert grammar contains `"correct_that"` as a `skill_id` literal. If grammar tests use a fixed 3-skill set, add a **dedicated** test with `BuiltinManifestCatalog.all` rather than rewriting the 3-skill snapshot.

GBNF is generated from manifests — no hand-edited `.gbnf` file. Confirm `FileSkillRegistry` / `InMemorySkillRegistry` picks up the new builtin via `BuiltinManifestCatalog.all` in the composition root (already the case).

### Named tests

- `CorrectThatSkillTests.testRecordsPair`
- `CorrectThatSkillTests.testMissingParameterFails`
- `BuiltinSkillRouterTests.testCorrectThatRequiresDictionary` (or extend existing router tests)
- `SkillRegistryTests.testCorrectThatIsInFullCatalogGrammar` — `routerGrammar()` contains `correct_that`

### Acceptance criteria

- [ ] Named tests pass; existing builtin tests updated for the new `BuiltinSkillRouter` init.
- [ ] Manual: Command Mode "correct that alpha should be beta" → Overlay success; `dictionary.json` contains `beta` / `alpha`.
- [ ] Per-phase gate green.

---

## Phase 3: Whisper bias-prompt consumption

**User stories**: 6, 8, 9, 13

### What to build

1. `TokenCounting.swift` + `BiasPromptBudget.swift` + `RecencyWeight.swift` (`weight = 0.5 ^ (ageDays / halfLifeDays)`).
2. `BiasPromptBuilder.swift` — `func build(promotedEntries:extraPhrases:counter:config:now:) -> String?`. Dictionary greedy fill; then extra phrases (app names) while tokens remain; join with `", "`. Nil if empty.
3. `Sources/WhisperSTTEngine/WhisperTokenCounter.swift` — conform `TokenCounting`. Use loaded whisper context if required. Document the C symbol used.
4. **`CommandModeDriver`:** add `makeInitialPrompt: @Sendable () async -> String?` stored property. In `resolve`, use `await makeInitialPrompt()` instead of calling `appNameBiasPrompt` directly. Keep `appNameBiasPrompt` as a public/internal static for the composition root to reuse. Default in `init`: if the new param is required (prefer required, no default) then **every test constructing `CommandModeDriver` must pass a closure** — update those tests. Composition root:

   ```
   let store = dictionaryStore
   let catalog = installedApps
   let counter = WhisperTokenCounter(engine: engine) // or a lazy wrapper
   let makePrompt: @Sendable () async -> String? = {
     let names = await CommandModeDriver.appNameBiasPrompt(catalog) // returns joined string or nil
     let extra = names?.split(separator: ", ").map(String.init) ?? []
     return BiasPromptBuilder().build(
       promotedEntries: await store.promotedEntries(),
       extraPhrases: extra,
       counter: counter,
       config: .default,
       now: Date())
   }
   ```

   Pass the same closure to `DictationDriver.makeInitialPrompt`.

5. Headless tests use a fake counter (`struct FakeCounter: TokenCounting { func tokenCount(_ t: String) -> Int { max(1, t.count / 4) } }`) — **production never uses this type**.

**Stop condition:** if `whisper_tokenize` cannot be linked, do not ship Phase 3. Report the header search you did.

### Named tests

- `RecencyWeightTests.testHalfLifeHalvesScore`
- `BiasPromptBudgetTests.testStopsBeforeExceedingBudget`
- `BiasPromptBudgetTests.testHigherScoreFirst`
- `BiasPromptBuilderTests.testDictionaryTermsPrecedeAppNames`
- `BiasPromptBuilderTests.testNilWhenNothingFits`
- `CommandModeDriverTests` updated: injected prompt is passed to `MockSTTEngine` (extend mock to record `lastInitialPrompt` if missing).

### Acceptance criteria

- [ ] Named tests pass.
- [ ] Both drivers receive the merged prompt (assert in driver tests).
- [ ] Real tokenizer compiles in `WhisperSTTEngine`; `just app` links.
- [ ] Per-phase gate green.

---

## Phase 4: Cleanup-prompt substitution injection

**User stories**: 7, 8

### What to build

- `SubstitutionListBuilder.swift` — top N promoted pairs by the same score, format each line `` `mishearing` -> `correct` `` (backticks optional; pick one format and test it). Empty → `none.` (matches P5a builder).
- `DictationDriver.dictionarySubstitutions` closure supplied from `AppCoordinator` via `SubstitutionListBuilder` + store.
- `CleanupPromptBuilder` already interpolates the slot (P5a). Add a Dictation test that a non-empty substitution list appears in the user prompt sent to `MockLLMClient`.

### Named tests

- `SubstitutionListBuilderTests.testTopNCap`
- `SubstitutionListBuilderTests.testOnlyPromoted`
- `DictationDriverTests.testCleanupPromptContainsSubstitution` (in `Tests/DictationTests`, allowed to import Personalization **or** just pass a closure returning a fixed string — prefer closure so `Dictation` still does not depend on `Personalization`)

### Acceptance criteria

- [ ] Named tests pass.
- [ ] Manual: after `correct_that`, dictation cleanup prompt (visible in a debug log **only if one already exists** — do not add telemetry) / behavior replaces the mishearing. If no log exists, the driver test is the gate; manual is best-effort.
- [ ] Per-phase gate green.

---

## Phase 5: Dictionary Settings pane

**User stories**: 3, 4, 11

### What to build

- `App/Settings/DictionaryPane.swift` — list entries (`correct_term` primary, mishearings secondary), delete button, add sheet (`mishearing` optional + `correct_term` required). Manual add with empty mishearing still creates a promoted explicit entry (custom vocabulary).
- Register pane: `id: "dictionary", title: "Dictionary", systemImage: "text.book.closed"` in `SettingsRootView.panes`.
- `AppCoordinator` publishes entries (reload on appear). Mutations go through `DictionaryStore`.
- Reset control: confirmation `NSAlert` or SwiftUI confirmationDialog titled `Reset dictionary?` — deletes file / `replaceAll([])`. **Not** hooked to `HistoryWipe`.
- Confirm existing `HistoryWipe` tests still exclude `dictionary.json`. Add `HistoryWipeTests.testDictionaryFileOutOfScope` if missing.

### Named tests

- Store-level `DictionaryStoreTests.testReplaceAllClearsFile`
- `HistoryWipeTests.testDictionaryFileOutOfScope` (Persistence tests)

Pane UI is manual.

### Acceptance criteria

- [ ] Pane lists / add / delete / reset work manually.
- [ ] Wipe history does not delete `dictionary.json`.
- [ ] Per-phase gate green.

---

## Execution notes

- Sequential: 1 → 2 → 3 → 4 → 5.
- Phase 2 is the P4 registry cut. Phase 3 is the Whisper tokenizer risk. Phase 4 needs P5a cleanup.
- Do not start P6/P7 work. Do not fold deferred P4 bugs into this plan.
