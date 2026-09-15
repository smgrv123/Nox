# Sidecar determinism for dictation

**Problem.** Tone cleanup fires or is skipped at random between dictations.

**Root cause (measured, not guessed).** The idle timer is activity-based and correct:
`IdleUnloadPolicy.tier16IdleThreshold = 180`s, checked on a 5s poll while `.ready`, reset by
`SidecarLifecycleController.recordActivity()`. Two things make it feel random:

1. Activity is recorded only when dictation reaches `resolveEndpoint` — i.e. only when cleanup
   actually runs. A raw-insert utterance extends the lease by nothing.
2. `warmDictationSidecarInBackground()` fires from `isDictationSidecarReady()`, which the driver
   calls **after** transcription. The warm starts too late to help the utterance that triggered
   it; it only helps the next one.

So the sidecar unloads 180s after the last *successful* cleanup, and the gap between utterances
is longer than that.

**Decisions (user-confirmed).** Mid-launch wait deadline **2s**. Activity scope **widened** —
any sidecar request counts, not dictation only.

**Key simplification.** `AppCoordinator.noteLLMActivity()` already records activity *and*
relaunches the sidecar when it was idle-unloaded. "Warm at key-down" and "hold the lease open"
are therefore one seam, not two.

---

## Phase 1 — Readiness policy (headless, TDD)

- [x] `Sources/Dictation/SidecarReadinessPolicy.swift` — new pure type:
      `SidecarReadiness` (`.ready` / `.launching` / `.unavailable`),
      `SidecarWaitDecision` (`.proceed` / `.waitUpTo(TimeInterval)` / `.insertRaw`),
      `launchWaitDeadline: TimeInterval = 2`, `decide(_:) -> SidecarWaitDecision`.
- [x] `Tests/DictationTests/SidecarReadinessPolicyTests.swift` — ready → proceed;
      launching → waitUpTo(2); unavailable → insertRaw; deadline constant is 2.

## Phase 2 — Driver seams

- [x] `DictationDriver`: replace `sidecarReady: @Sendable () async -> Bool = { true }` with
      `sidecarReadiness: @Sendable () async -> SidecarReadiness = { .ready }` and
      `awaitSidecarReady: @Sendable (TimeInterval) async -> Bool = { _ in true }`.
- [x] Cleanup path consumes the policy: `.proceed` → chat; `.waitUpTo(d)` → `awaitSidecarReady(d)`,
      false → `.sidecarNotReady(raw)`; `.insertRaw` → `.sidecarNotReady(raw)`.
      The `sidecarNotReadySummary` copy is unchanged.
- [x] Add `noteSidecarActivity: @Sendable () async -> Void = {}`.
      Called fire-and-forget from `begin(mode:)` when `cleanupEnabled()` is true (warm at
      key-down — hands the loader the whole utterance), and again after the flow completes
      (so the 180s countdown starts at flow end, not mid-flow).
      Must never block capture or insert.
- [x] Update existing `DictationDriverTests` that pass `sidecarReady:`.

## Phase 3 — App wiring

- [x] `App/AppCoordinator+CommandMode.swift`: supply the three closures.
      `sidecarReadiness` maps `manager.state` → `.ready` / `.launching` / `.unavailable`
      (`.stopped`, `.unhealthy`, `.failed` all → `.unavailable`) without starting the sidecar.
      `awaitSidecarReady` reuses `waitForSidecarReady(manager, appLog:, timeout:)` (300ms poll).
      `noteSidecarActivity` → `noteLLMActivity()`.
- [x] Confirm command routing also flows through `noteLLMActivity()` (the widened scope). If it
      resolves its endpoint by another path, route that through the same chokepoint.
- [x] Retire `isDictationSidecarReady()` if nothing else calls it.

## Phase 4 — Tests + gate

- [x] `DictationDriverTests`: key-down notes activity when cleanup enabled; does NOT when
      disabled; `.launching` + wait succeeds → chat runs; `.launching` + wait times out → raw
      with the exact summary; flow completion notes activity.
- [x] `just check` + `just app`, SwiftLint 0 warnings.

---

## Out of scope

Raising the idle threshold or making the sidecar resident (non-resident path was chosen
deliberately). Confirm-Back supersession. Any latency work — that is the next item.

## Review

All three phases landed. `just check` green (**1042 tests**, 2 skipped, 0 failures — up from
1032) and `just app` **BUILD SUCCEEDED**. Changes are unstaged, nothing committed.

**Files.** New: `Sources/Dictation/SidecarReadinessPolicy.swift`,
`Tests/DictationTests/SidecarReadinessPolicyTests.swift`,
`Tests/DictationTests/DictationDriverTests+SidecarReadiness.swift`. Modified:
`Sources/Dictation/DictationDriver.swift`, `App/AppCoordinator+CommandMode.swift`,
`App/AppCoordinator+Sidecar.swift`, `Tests/DictationTests/TestSupport.swift`,
`DictationDriverTests+Bypass.swift`, `DictationDriverTests+History.swift`.

**Deleted:** `isDictationSidecarReady()` and `warmDictationSidecarInBackground()` — both
superseded by the readiness closure and key-down warm.

### Two defects caught in review, not by the gate

1. **Fabricated justification in a doc comment.** The generated comment on
   `launchWaitDeadline` claimed the 2s value was "empirically validated", that cold loads take
   "minutes, not seconds", and that warm restarts occupy a "~100ms window". None of that was
   measured. Rewritten to state plainly that it is a product decision, and to point at
   `DictationHistoryEntry.model_load_ms` as the data that should govern any revision.

2. **Regression: the Sidecar manager could never be created from dictation.** Deleting
   `warmDictationSidecarInBackground()` removed dictation's only call to
   `ensureSidecarManagerIfModelProvisioned()`, and `noteLLMActivity()` bailed on a nil
   `sidecarManagerInstance`. On a fresh launch whose first action is dictation, key-down warm
   would no-op, readiness would read `.unavailable`, and cleanup would never run until the
   user happened to issue a Command Mode utterance. Fixed by routing `noteLLMActivity()`
   through `ensureSidecarManagerIfModelProvisioned()`, which still no-ops correctly when the
   model blob isn't downloaded. **Both gates passed while this bug was present** — it is a
   first-launch-ordering fault, and nothing in the headless suite or `just app` exercises it.

### Not yet verified by hand

The gates prove it compiles and the units behave. They do not prove the user-visible fix.
Worth checking manually:

- Dictate twice with a gap longer than 180s. The second utterance should still be cleaned,
  where before it would silently insert raw.
- Quit the sidecar (or launch fresh), then dictate. Key-down should start the warm; a long
  utterance should find it `.ready` or `.launching` by the time transcription ends.
- Confirm the 2s wait never feels like a stall on a genuinely cold sidecar — it should fall
  through to a raw insert, not block.
