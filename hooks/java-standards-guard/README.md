# java-standards-guard (PreToolUse hook)

Enforces the always-on [`java-standards`](../../rules/java-standards.md) rule
*deterministically*. Before Claude writes a `.java` file, this inspects the new
content and **blocks** the edit if it introduces a pattern the rule forbids,
returning a precise reason so Claude rewrites it correctly — before the bad code
ever reaches disk.

The rule alone is advisory (the model usually follows it, but can drift on a long
task). This hook makes the hard bans non-negotiable.

## What it blocks (hard, high-confidence only)

| Pattern | Why |
|---|---|
| `@Data` | Forbidden Lombok annotation; use `@RequiredArgsConstructor`/`@Builder`. |
| `org.mapstruct` / `@Mapper` | No external mappers; transformation belongs to the object (static `fromDomain`). |
| `System.out/err.print*`, `printStackTrace()` | Use structured SLF4J logging (see the log-standardization skill). |
| `throw new RuntimeException/IllegalStateException/IllegalArgumentException(` | Use named domain exceptions or sealed result types, not generic control-flow exceptions. |

It deliberately does **not** try to enforce the softer, contextual parts of the rule
(DTOs-as-records, dependency inversion, pattern-matching-over-`instanceof`). A regex
gate would produce false positives there; those are better handled by the
[reviewer agent](../../agents/spring-java-reviewer.md) and the build hook.

## Install (in the consuming Spring project)

```
mkdir -p .claude/hooks
cp java-standards-guard.sh .claude/hooks/
chmod +x .claude/hooks/java-standards-guard.sh
```

Merge `settings.example.json` into the repo's `.claude/settings.json`. Requires `jq`.

Pairs well with `java-build-check` (Stop hook): this catches banned *patterns* up
front; the build hook catches anything that doesn't *compile or test* at the end of
the turn.

## Token cost

Silent unless it blocks; a block is a handful of lines. Effectively free.
