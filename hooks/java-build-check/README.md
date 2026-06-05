# java-build-check (Stop hook)

A Claude Code hook that verifies the build **once, when the agent finishes its
turn** — instead of after every edit. Use this when you want Claude to compile/test
a *complete* set of changes before handing control back to you, rather than paying
build latency on every individual file edit.

This is the heavier counterpart to [`java-compile-check`](../java-compile-check)
(a `PostToolUse` hook). Pick based on the trade-off below; you can also run both.

## PostToolUse vs Stop — which to use

| | `PostToolUse` (per edit) | `Stop` (per turn) |
|---|---|---|
| Fires | After **every** matching edit | **Once**, when the agent ends its turn |
| Right command weight | Cheap only (`compile`) | Heavier OK (`test` / `verify` / `install`) |
| Feedback timing | Immediate — catches the breaking edit at once | Delayed — may build on top of a break first |
| Session feel | Slower (Maven/JVM startup every edit) | Faster (one run per turn) |
| Best for | Tight compile loop on each change | Verifying a finished task before handoff |

If you found per-edit too slow, this Stop hook is the better default: one build per
turn, and you can afford real tests.

## Install (in the consuming Spring project)

1. Copy the script:

   ```
   mkdir -p .claude/hooks
   cp java-build-check.sh .claude/hooks/
   chmod +x .claude/hooks/java-build-check.sh
   ```

2. Merge `settings.example.json` into the repo's `.claude/settings.json`.

3. Requires `jq`, `mvn`, and a JDK on `PATH`.

## Choosing the goals

Default is `mvn -q -B test`. Override per project by exporting `MVN_GOALS` before
starting the session:

```
export MVN_GOALS="-q -B verify"          # + integration tests
export MVN_GOALS="-q -B clean install"   # heaviest: full clean, tests, package
```

Because this runs once per turn, `clean install` is *affordable* here in a way it
never is in a `PostToolUse` hook — this is the place to put it if you want it.

## Two behaviours worth knowing

**It blocks the stop on failure.** A `Stop` hook that exits 2 doesn't just report —
it prevents the agent from finishing and feeds the errors back, so Claude keeps
working to fix the build before it hands control to you. That's usually what you
want: no "done!" on a red build.

**Loop guard.** Because a blocked stop makes the agent continue, a permanently
failing build could loop. Claude Code sets `stop_hook_active: true` while the agent
is already continuing due to this hook; the script detects it and does **not** block
a second time, so a genuinely unfixable failure won't trap the session.

## Token cost

Same discipline as the compile hook: silent on success (0 tokens), and on failure
only `[ERROR]` / test-failure lines, capped at 50. Running once per turn also means
far fewer invocations than the per-edit hook, so total cost is typically lower even
though each run does more.
