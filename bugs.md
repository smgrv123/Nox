# Known bugs

Observed but not yet reproducible on demand. Each entry stays here until it either
replicates (then it gets fixed) or is disproved.

---

## B1 · Confirm-Back modal vanishes before it can be actioned

**Status:** open · observed once · root cause unknown
**Pillar:** P5a · Dictation Core
**Severity:** correctness — the utterance is lost, not just delayed

### What was seen

During a three-run dictation test, the second run's Confirm-Back modal disappeared from the
Overlay before it could be approved. Reported at the time as *"somehow I could not paste the
second one, the modal dismissed very quickly."* The dictated text never landed.

### What it is NOT

- **Not the Confirm-Back timeout.** That was 20s at the time of the observation (now 10s), far
  longer than the modal was actually on screen. The timeout also no longer destroys text — it
  copies to the clipboard (`DictationDriver.confirmBackTimedOut()`), so even a timeout would
  not produce this symptom today.
- **Not a scanner verdict change.** The text reached Confirm-Back, meaning the scan had already
  returned `.confirm`.

### Leading hypothesis (unverified)

A second hotkey press bumps the driver's generation counter while a Confirm-Back is pending.
`DictationDriver` guards delivery on `gate.generation == pending.generation`, and
`begin(mode:)` clears `pendingInsert`. So starting a new utterance while a confirm is
outstanding would silently discard the stashed text with no user-visible explanation — the
modal would simply go away.

If that is the mechanism, the bug is *supersession*, not a timeout, and the fix is to decide
deliberately what a new utterance should do to a pending confirm: reject it (with a summary),
copy it to the clipboard as the timeout path does, or refuse to start until it is resolved.

### How to reproduce (untested)

1. Dictate into a terminal so the C11 rule forces Confirm-Back.
2. Before touching Approve or Reject, press and hold the dictation hotkey again.
3. Watch whether the pending modal disappears without a summary.

If that reproduces it, the hypothesis holds and the fix is scoped to `DictationDriver`'s
generation guard around `pendingInsert`.

### Notes

Deliberately not fixed blind. Guessing at a supersession policy without a reproduction risks
changing behaviour that is currently correct — a superseded utterance *should* usually be
discarded; the question is only whether the user is told.
