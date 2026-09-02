# Plan: P3 · Safety Guard

> Source PRD: [`specs/P3-safety-guard.md`](../specs/P3-safety-guard.md)
> Grounded in `docs/04-hld.md` §8 and `docs/05-lld.md` §3.6, §4.3, §11.
> Execution: `/execute-plan --tdd`, **one phase at a time**, each gated + paused for review before the next.

## Architectural decisions

Durable decisions that apply across all phases:

- **Pure, synchronous, value type (locked):** `DangerousCommandScanner` is a `struct`, no I/O, no shared state, no execution. It treats all input as string data. It is callable from any thread, any context. This is the INV-6 invariant.
- **Module stays in `Sources/DangerousCommandScanner/`:** the existing module location is correct. Tests in `Tests/DangerousCommandScannerTests/`. Both already registered in `Package.swift`.
- **Three-layer internal architecture:** (1) **Tokenizer** — a POSIX-ish shell lexer that produces a token stream; (2) **Parser** — recursive-descent builder that assembles tokens into a command tree; (3) **Rule Engine** — walks the tree and evaluates structured rules against each node's `argv`. This mirrors the LLD §4.3 Phases A/B/C/D.
- **Structured `argv` matching, not whole-line regex:** the existing regex-based rules are replaced by structural matchers that inspect `argv[0]` (program name) + flags + operands. This is what makes `rm -r -f`, `rm -rf`, `rm --recursive --force` all match the same rule. The current regex approach is the scaffold — it's replaced, not extended.
- **Data types from LLD §3.6:** `ScanContext`, `ScanVerdict` (renamed from the current simpler enum), `Finding`, `RuleID`, `Severity`. The existing `ScanVerdict` is migrated to the richer LLD shape.
- **Depth limit 8 (PROVISIONAL):** recursive descent into `$()`, backticks, `sh -c`, `eval`, etc. is capped at depth 8. Hitting the limit produces a `confirm` finding.
- **Fail-closed posture (MUST):** unknown/unparseable fragments → `confirm` at minimum. False positives are acceptable; false negatives are not.
- **Testing posture:** TDD (red-green-refactor), tests-first, headless via `swift test`. Every rule, every obfuscation pattern, every edge case gets a test before the implementation. The existing 10 tests are carried forward and adapted to the new API.
- **Per-phase gate (MUST, all phases):** `just check` green (format-check + SwiftLint + `swift build` + `swift test`) **and** `just app` builds **and** SwiftLint reports **0 warnings**. Phase is not "done" until these pass and the user has reviewed.

---

## Phase 1: Data types + shell tokenizer (TDD)

**User stories**: 1, 6, 8, 16, 18

### What to build

The foundation: the LLD §3.6 data types (`ScanContext`, `Finding`, `RuleID`, `Severity`, and the richer `ScanVerdict`) and the POSIX-ish shell tokenizer (LLD §4.3 Phase A). The tokenizer scans character-by-character producing a token stream that honors: single quotes (literal), double quotes (allow `$`, `` ` ``, `\`), backslash escapes, `$'...'` ANSI-C quoting, and operators `| || & && ; ( ) { } < > >> $( )` and backticks. It preserves quoting metadata and records nesting boundaries. It never expands variables or globs. Unknown/odd bytes are kept as opaque tokens (fail-closed).

The existing `ScanVerdict` (`allow`/`confirm(reason:matched:)`/`hardBlock(reason:matched:)`) is migrated to the richer shape with `Finding` arrays. The existing `DangerousCommandScanner.scan(_:)` method signature gains a `context:` parameter (with a default for backward compatibility during migration).

### Acceptance criteria

- [ ] `ScanContext`, `Finding`, `RuleID`, `Severity` types defined per LLD §3.6.
- [ ] `ScanVerdict` migrated from `allow/confirm/hardBlock` with single reason/matched to `clean/confirm(findings:)/hardBlock(findings:)` with `[Finding]`.
- [ ] Shell tokenizer implemented test-first: correctly tokenizes single-quoted strings, double-quoted strings (with `$`/backtick/`\` handling), backslash escapes, `$'...'` ANSI-C quoting, pipe/semicolon/`&&`/`||` operators, `$(...)` and backtick nesting boundaries.
- [ ] Tokenizer treats unknown/unparseable bytes as opaque tokens (never crashes, never silently drops).
- [ ] Existing 10 tests adapted to the new `ScanVerdict` shape — all still pass (behavior unchanged, API updated).
- [ ] Per-phase gate green (`just check`, `just app`, 0 lint warnings).

---

## Phase 2: Command-tree parser + recursive descent (TDD)

**User stories**: 4, 5, 9, 15, 16

### What to build

The recursive-descent parser (LLD §4.3 Phase B) that builds a command tree from Phase 1's token stream. Split the token stream into pipelines (on `|`, `||`, `&&`, `;`, newline). Each pipeline contains simple commands with `argv[0]` + arguments. Recurse into nested command strings: `$(...)`, backticks → parse inner text as a child tree. `sh -c`/`bash -c`/`zsh -c` → parse the `-c` argument as a child tree. `eval` → parse the argument. `xargs [cmd]`, `find ... -exec [cmd] ;`, `env ... [cmd]`, `nice`/`nohup`/`time [cmd]`, `ssh host [cmd]` → parse the wrapped command. Depth-limit to 8.

Handle decode-and-pipe patterns: `base64 -d | sh` → flag the pattern itself; if the encoded payload is a static literal, attempt one decode pass and scan the result.

### Acceptance criteria

- [ ] Parser builds a correct command tree from tokenized input: pipes, `&&`, `||`, `;` split into separate pipeline segments; each segment has `argv[0]` + args.
- [ ] `$(...)` and backtick substitutions are recursed into: `echo $(rm -rf /)` produces a child node with `argv[0] = "rm"`.
- [ ] `sh -c "rm -rf *"`, `bash -c "rm -rf *"`, `zsh -c "rm -rf *"` → the `-c` argument is parsed as a child tree.
- [ ] `eval "rm -rf *"` → the argument is parsed as a child tree.
- [ ] `xargs rm -rf`, `find . -exec rm -rf {} ;`, `env rm -rf /`, `nohup rm -rf /`, `ssh host "rm -rf /"` → wrapped commands are parsed as children.
- [ ] `base64 -d | sh` → the pattern itself is flagged; static-literal decode is attempted.
- [ ] Depth limit of 8 is enforced; exceeding it produces a finding rather than infinite recursion.
- [ ] Each node carries a `path` (nesting trail) from the root, e.g. `["pipe", "sh -c"]`.
- [ ] Per-phase gate green (`just check`, `just app`, 0 lint warnings).

---

## Phase 3: Structured rule engine — Hard-Block + Confirm rules (TDD)

**User stories**: 2, 3, 7, 10, 11, 17

### What to build

Replace the existing regex-based rules with the full structured rule engine (LLD §4.3 Phase C + Phase D). Rules inspect `argv` structurally: program name (after normalizing away shell quoting/escaping) + flags + operands. Implement the complete Hard-Block list (H1–H7) and Confirm list (C1–C12) from LLD §11.1–11.2.

**Hard-Block (H1–H7):**
- H1: `sudo`, `su`, `doas`, `pkexec`, `sudoedit`
- H2: `csrutil`, `spctl`, `nvram` (write), `bputil`
- H3: `security dump-keychain`, `security find-generic-password -w`, keychain export
- H4: `launchctl` targeting Aide's own jobs or system daemons
- H5: `dd` to device, `diskutil erase/reformat/partitionDisk`, `mkfs*`, `newfs*`, `asr` restore
- H6: Fork bombs
- H7: Aide-generated automations: entire confirm subset escalated to Hard-Block (context-dependent)

**Confirm (C1–C12):**
- C1: `rm` with recursive/force flags
- C2: `srm`, `shred`, `rm -P`
- C3: `curl|sh`, `wget|sh` piped remote execution
- C4: `chmod -R 777`, recursive `chown`/`chgrp`
- C5: `dd` file-to-file (not device)
- C6: `kill -9 -1`, broad `killall`/`pkill`
- C7: Writes/deletes outside `$HOME` or system-critical `~/Library` areas
- C8: Shell profile edits, `crontab -r`
- C9: `git clean -fdx`, `git reset --hard`, `git push --force`
- C10: `mv`/`cp` overwriting system/broad paths; `find -delete`; `find -exec rm`
- C11: Dictation into terminal (bundle-ID allowlist) — any command text
- C12: Unparseable / depth-limit-exceeded (fail-closed)

Wire the verdict combiner: any hardBlock finding → `hardBlock`; any confirm finding → `confirm`; check `ScanContext.manifestID` for H7 escalation; else `clean`.

### Acceptance criteria

- [ ] All H1–H7 Hard-Block rules implemented test-first with structural `argv` matching.
- [ ] All C1–C12 Confirm rules implemented test-first with structural `argv` matching.
- [ ] `rm -rf`, `rm -r -f`, `rm --recursive --force`, `rm -fr` all match C1 (flag-order-independent).
- [ ] `sudo`, `su`, `doas`, `pkexec`, `sudoedit` match H1 at any nesting depth.
- [ ] `ScanContext.manifestID` present → confirm-tier destructive rules escalate to Hard-Block (H7).
- [ ] `ScanContext.channel == .dictatedOneOff` with terminal `destinationBundleID` → C11 confirm.
- [ ] Verdict combiner: hardBlock wins over confirm; confirm wins over clean.
- [ ] Safe commands return `.clean`: `ls -la`, `git status`, `echo 'sudoku'`, non-recursive `rm file.txt`.
- [ ] Per-phase gate green (`just check`, `just app`, 0 lint warnings).

---

## Phase 4: Path restriction rules (TDD)

**User stories**: 13, 14

### What to build

The LLD §11.3 path-restriction rules. Resolve each write/delete target path lexically (expand `~` → `$HOME`, resolve `.`/`..` — no filesystem I/O, no symlink following). Flag writes/deletes outside `$HOME` as C7. Flag writes into system-critical zones inside `$HOME` (`~/Library/LaunchAgents`, `~/Library/Preferences`, `~/Library/Keychains`, `~/.ssh`, `~/.gnupg`) even though they're inside `$HOME`. Wildcard/glob targets (`*`, `**`, `?`) that could expand outside declared paths → fail-closed → Confirm.

Wire path checking into the rule engine so that `rm`, `mv`, `cp`, `dd`, write-redirect (`>`/`>>`) targets are path-checked.

### Acceptance criteria

- [ ] Lexical path resolution: `~` → `$HOME`, `.`/`..` resolved, no filesystem access.
- [ ] `rm -rf /usr/local/bin` → C7 confirm (outside `$HOME`).
- [ ] `rm -rf ~/.ssh/id_rsa` → confirm (system-critical zone inside `$HOME`).
- [ ] `rm -rf ~/Downloads/junk` → C1 (recursive rm, but not path-flagged — inside `$HOME`, not system-critical).
- [ ] `echo "data" > /etc/hosts` → C7 confirm (write outside `$HOME`).
- [ ] `rm -rf *` → fail-closed (glob could expand anywhere → confirm).
- [ ] Manifest `file_write_paths` check: a write inside declared paths + inside `$HOME` → allowed; outside → flagged.
- [ ] Per-phase gate green (`just check`, `just app`, 0 lint warnings).

---

## Phase 5: Obfuscation patterns + comprehensive test corpus (TDD)

**User stories**: 4, 5, 8, 17

### What to build

The LLD §11.4 obfuscation pattern detection, plus a comprehensive test corpus that exercises every rule, every nesting pattern, and every evasion technique. This is the "correctness corpus" the pillar's Done line depends on.

**Obfuscation patterns:**
- Character-escaped evasions: `r\m -rf`, `r""m -rf`, `'r'm`, IFS tricks → normalize during tokenization so `argv[0]` reconstructs to `rm`.
- Hex/unicode-encoded program names, `$'...'` ANSI-C quoting → decode before matching.
- `base64 -d`/`--decode` piped to shell → flag pattern + attempt decode of static literals.
- `openssl enc -d ... | sh`, `xxd -r ... | sh`, `uudecode`, `printf '\x..' | sh` → flag as obfuscation.
- `eval` of concatenated/constructed strings → recurse into argument; if unresolvable → confirm.

**Test corpus:**
- All H1–H7 with multiple spellings and nesting depths.
- All C1–C12 with edge cases.
- All obfuscation patterns from §11.4.
- A battery of safe commands that must NOT be flagged.
- Multi-layer nesting: `bash -c "$(echo 'sudo reboot')"`.
- Flag-separated recursive rm: `rm -r -f`, `rm --recursive`, etc.
- Words containing rule keywords: `sudoku`, `pseudocode`, `surname`, `format`, `discuss`.

### Acceptance criteria

- [ ] `r\m -rf /` → caught (character-escape normalization).
- [ ] `echo cm0gLXJmIC8= | base64 -d | sh` → confirm (base64 decode-and-exec obfuscation). Static literal decoded and inner `rm -rf /` scanned.
- [ ] `bash -c "$(echo 'sudo reboot')"` → hardBlock (multi-layer nesting, `sudo` found at depth 3).
- [ ] `eval "rm -rf /"` → caught (eval recursion).
- [ ] `$'\x73\x75\x64\x6f' reboot` → hardBlock (hex-encoded `sudo` via ANSI-C quoting).
- [ ] Safe corpus: `ls`, `git status`, `echo 'sudoku is fun'`, `rm file.txt`, `grep -r pattern`, `find . -name '*.log'`, `curl https://example.com` (no pipe to shell) → all `.clean`.
- [ ] Comprehensive test file(s) with ≥60 test cases covering the full corpus.
- [ ] Per-phase gate green (`just check`, `just app`, 0 lint warnings).

---

## Phase 6: Protocol conformance + integration polish

**User stories**: 1, 9, 10, 18

### What to build

Finalize the `DangerousCommandScanner` protocol conformance from LLD §3.6. Ensure the public API matches the protocol signature exactly (`scan(_ command: String, context: ScanContext) -> ScanVerdict`). Add a convenience overload without `context:` that defaults to a safe context (for simple call sites). Clean up any remaining TODO markers from the existing code. Verify backward compatibility — all existing consumers (none yet beyond tests, but the API must be stable for P4/P5/P7). Run the full gate one final time.

### Acceptance criteria

- [ ] `DangerousCommandScanner` conforms to the `DangerousCommandScanner` protocol from LLD §3.6.
- [ ] Convenience `scan(_:)` overload (no context) defaults to `ScanContext(channel: .typedOneOff, destinationBundleID: nil, manifestID: nil)`.
- [ ] No `TODO` markers remain in `Sources/DangerousCommandScanner/`.
- [ ] All tests pass; comprehensive corpus green.
- [ ] Per-phase gate green (`just check`, `just app`, 0 lint warnings).

---

## Execution notes

- Phases 1–2 are sequential (Phase 2 depends on Phase 1's tokenizer).
- Phase 3 depends on Phase 2's command tree.
- Phase 4 depends on Phase 3's rule engine.
- Phase 5 depends on Phases 1–4 (full-stack obfuscation testing).
- Phase 6 depends on Phases 1–5 (final polish).
- All phases are strictly sequential — each builds on the previous.
- After each phase, pause for user review; apply feedback; proceed only on approval.
