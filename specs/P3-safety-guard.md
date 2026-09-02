# PRD — P3 · Safety Guard

> Pillar P3 of Aide (see [`docs/07-implementation-pillars.md`](../docs/07-implementation-pillars.md)).
> Grounded in [`docs/04-hld.md`](../docs/04-hld.md) §8 and [`docs/05-lld.md`](../docs/05-lld.md) §3.6, §4.3, §11.
> Status: draft spec · not yet planned.

## Problem Statement

Aide lets users speak commands that become executable code — built-in skill invocations, dictated terminal input, and (eventually) LLM-generated Script-Automations. The LLM routing these commands is probabilistic, can hallucinate, and is prompt-injectable. A single unguarded `sudo rm -rf /` reaching the shell would be catastrophic and unrecoverable. LLM self-censoring ("refuse dangerous requests") is not reliable — it's a probabilistic heuristic that can be jailbroken, tricked by paraphrasing, or simply wrong.

The product's safety promise requires a **deterministic, pattern-based, un-prompt-injectable guard** that sits between every "something executable was produced" event and "something executable runs." It must catch dangerous commands whether they're stated plainly (`sudo reboot`), hidden inside nested shells (`bash -c "rm -rf *"`), obfuscated through encoding (`echo cm0gLXJm | base64 -d | sh`), or spread across pipe segments. False positives (extra confirmations) are acceptable; **false negatives are not**.

Today the scanner exists as a first-pass regex classifier covering the highest-value blocklist entries, but it lacks the recursive descent, structured `argv` matching, and full rule coverage the design docs call for. This pillar completes it.

## Solution

A **Dangerous-Command Scanner** module (`DangerousCommandScanner`) that is:

- **Pure Swift, in-process, synchronous** — a value type with no I/O, no shared state, no execution. Callable from any thread, any context.
- **Pattern-based, never LLM** — deterministic; treats all input strings as data; cannot be prompt-injected (INV-6).
- **Recursive-descent** — parses shell syntax (pipes, `$()`, backticks, `sh -c`, `eval`, `xargs`, `find -exec`, etc.) into a command tree and scans every node, so nested payloads cannot hide.
- **Structured `argv` matching** — rules inspect program name + flags + operands structurally, not regex over the whole line, so `rm -rf`, `rm -r -f`, `rm --recursive --force` all match.
- **Two-tier verdict** — Hard-Block (privilege escalation, no override) vs Confirm (destructive but user-overridable via a distinct confirmation UI).
- **Context-aware** — accepts a `ScanContext` describing the channel (generated script, pre-execution, dictation, etc.) and destination, so Aide-generated automations get the strictest treatment (H7) and terminal dictation triggers a Confirm-Back.
- **Fail-closed** — unparseable fragments, depth-limit hits, and unknown constructs produce `confirm` at minimum, never `allow`.

## User Stories

### Core scanning
1. As a developer building on the scanner, I want a `scan(command, context)` call that returns a structured verdict, so I can gate any executable channel without building my own parser.
2. As a user, I want `sudo` and all privilege escalation to be **Hard-Blocked with no override**, so there is no voice-triggerable path to root on my machine.
3. As a user, I want destructive commands (`rm -rf`, `dd`, `mkfs`, etc.) to require a **distinct, explicit confirmation**, so I can still run them intentionally but never accidentally.
4. As a user, I want the scanner to catch dangerous commands hidden inside `bash -c "..."`, `$(...)`, backticks, `eval`, `xargs`, `find -exec`, and pipe chains, so that wrapping a dangerous command in another command doesn't bypass the guard.
5. As a user, I want base64-encoded payloads piped to a shell to be flagged, so that obfuscation doesn't bypass the guard.
6. As a user, I want the scanner to never execute, source, or expand anything it inspects, so that scanning itself is safe.

### Structured matching
7. As a user, I want `rm -rf`, `rm -r -f`, `rm --recursive --force`, and `rm -fr` to all be caught, so that flag ordering and spelling don't matter.
8. As a user, I want words like "sudoku" and "pseudocode" to NOT trigger the `sudo` rule, so that the scanner doesn't over-block on unrelated words.
9. As a developer, I want findings to carry a nesting path (e.g. `["pipe", "sh -c", "rm -rf"]`), so the UI can highlight exactly where the danger is.

### Channel awareness
10. As a developer, I want to pass a `ScanContext` with the channel type (generated script, pre-execution, hand-edit, dictated one-off, typed one-off), so the scanner can apply channel-specific rules.
11. As a user, I want Aide-generated automations to get **Hard-Block** treatment for the entire destructive subset (not just privilege escalation), so automations Aide wrote can never destroy my data.
12. As a user dictating into a terminal, I want the scanner to flag any command text for confirmation, so I can catch mistakes before they're inserted.

### Path restriction
13. As a user, I want writes/deletes outside `$HOME` to be flagged, so commands that touch system paths get a confirmation.
14. As a user, I want writes to system-critical zones inside `$HOME` (`~/.ssh`, `~/Library/LaunchAgents`, shell profiles) to be flagged even though they're inside my home directory.

### Fail-closed safety
15. As a user, I want deeply nested commands (beyond the depth limit) to require confirmation rather than being silently allowed.
16. As a user, I want unparseable command fragments to require confirmation rather than being silently allowed.

### Testing corpus
17. As a developer, I want a comprehensive test corpus covering all Hard-Block rules (H1–H7), all Confirm rules (C1–C12), safe commands, and obfuscation patterns, so that regressions are caught immediately.
18. As a developer, I want the scanner to be purely headless-testable (`swift test`), with no process spawning, no I/O, and deterministic results.

## Scope

### In scope
- POSIX-ish shell tokenizer (single/double quotes, backslash escapes, operators, `$()`, backticks).
- Recursive-descent command-tree builder with depth limiting.
- Full Hard-Block rule set (H1–H7 per LLD §11.1).
- Full Confirm rule set (C1–C12 per LLD §11.2).
- Path-restriction rules (LLD §11.3) — lexical path resolution, no filesystem I/O.
- Obfuscation pattern detection (LLD §11.4) — `base64 -d | sh`, `eval`, `sh -c`, character-escaped evasions, `$'...'` ANSI-C quoting.
- `ScanContext` + `Finding` types per LLD §3.6.
- `DangerousCommandScanner` protocol conformance.
- Comprehensive test corpus (TDD, headless).

### Out of scope
- **Confirmation UI** — the Confirm-Back and Hard-Block UI surfaces are P1's `ConfirmationModal` (already built) and P4's `Dispatcher`. The scanner only returns data.
- **Wiring to consumers** — connecting the scanner to `Dispatcher`, `Dictation`, `ScriptAutomation` is P4/P5/P7 scope. P3 delivers the pure function; consumers call it.
- **Variable/glob expansion** — the scanner never expands `$VAR` or `*`; it treats unresolvable content as suspicious (fail-closed).
- **Symlink following** — no filesystem I/O at scan time.
- **Runtime sandboxing** — P3 is the pre-execution gate; runtime sandboxing (if any) is a separate concern.

## Interfaces

### Input
```swift
struct ScanContext {
    enum Channel { case generatedScript, preExecution, handEdit, dictatedOneOff, typedOneOff }
    let channel: Channel
    let destinationBundleID: String?
    let manifestID: String?
}
```

### Output
```swift
enum ScanVerdict: Equatable {
    case clean
    case confirm(findings: [Finding])
    case hardBlock(findings: [Finding])
}

struct Finding: Equatable {
    let rule: RuleID
    let severity: Severity           // .hardBlock / .confirm
    let matchedText: String
    let explanation: String
    let path: [String]               // nesting trail
}
```

### Protocol
```swift
protocol DangerousCommandScanner {
    func scan(_ command: String, context: ScanContext) -> ScanVerdict
}
```

## Success Criteria

1. `just check` green — all tests pass, 0 lint warnings, build succeeds.
2. The scanner correctly classifies the full corpus of malicious/benign commands from the LLD's Hard-Block (H1–H7) and Confirm (C1–C12) lists, including nested and obfuscated cases.
3. Safe commands (`ls`, `git status`, `echo 'sudoku'`, non-recursive `rm`) return `.clean`.
4. No false negatives in the test corpus — every known dangerous pattern is caught.
5. Unparseable and depth-exceeded fragments return `confirm` at minimum.
6. The scanner is pure, synchronous, headless — no I/O, no process, callable from `swift test`.
