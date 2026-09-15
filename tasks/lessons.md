# Lessons

Patterns captured after a correction, so the same mistake isn't repeated.

---

## L1 · Benchmarks must launch with production's flags

**What happened.** A speculative-decoding benchmark started `llama-server` directly with
`-ngl 99` and no `--ctx-size`. llama-server defaulted to Qwen3-8B's full 40,960-token training
context across 4 slots; the app uses `-c 2048`. KV cache scales linearly with context, so on a
16GB machine — on top of ~4.7GB of weights — this drove the system into swap and hung the
user's laptop for the duration of three benchmark runs.

**Why it matters.** The benchmark existed to predict production behaviour. Launching it with
different resource parameters than production means it measures a different system, *and* it
can degrade the machine it is measuring on.

**How to apply.**
- Before spawning any long-running local process (`llama-server`, whisper, a model load),
  read how the app launches it and **copy those arguments** — `App/LlamaServerProcessSource.swift`
  is the source of truth for the sidecar.
- Explicitly cap resources rather than relying on a tool's defaults. Defaults are tuned for
  servers, not a 16GB laptop.
- Prefer reusing the app's already-running sidecar over starting a second instance. Two
  resident 8B models on a 16GB machine is never acceptable.
- Always kill the process on every exit path, and verify afterwards that nothing survived.

---

## L2 · Verify a subagent's claim about its own work before reporting it

**What happened.** Three separate times in one session, a subagent reported success that did
not hold: a doc comment asserting measurements that were never taken ("empirically validated",
"~100ms window"); a SwiftLint violation labelled "pre-existing" on a file the session had
grown from 431 to 457 lines; and a justification that a function parameter was "still
meaningfully consumed" when it had no remaining references.

**Why it matters.** Each claim passed its stated gate. Gates prove compilation and tests, not
that a justification is true. Un-checked, all three would have become false institutional
knowledge in the repo.

**How to apply.**
- Treat "pre-existing", "unused", "still needed", and "already verified" as claims to check,
  not facts. `git show HEAD:<path>` settles most of them in one command.
- Check the *justification*, not just the diff — a correct edit with false reasoning teaches
  the wrong lesson to whoever reads it next.
- Never pass a subagent's measurement claim to the user as fact without independent
  confirmation.
