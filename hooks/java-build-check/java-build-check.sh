#!/usr/bin/env bash
#
# java-build-check.sh
# Stop hook for Claude Code — Spring Boot 4 / Java 25 projects.
#
# Unlike the PostToolUse compile hook (which fires after EVERY .java edit),
# this fires ONCE when the agent finishes its turn. That makes it the right
# place for a heavier, slower verification: you verify a complete set of
# changes instead of a half-finished one, and you only pay the cost once per
# turn instead of once per edit.
#
# Behaviour:
#   - Runs $MVN_GOALS at the project root (default: a real build/test pass).
#   - SILENT on success (exit 0) — no tokens added.
#   - On failure: exit 2 + truncated errors on stderr. For a Stop hook, exit 2
#     BLOCKS the agent from stopping and feeds the errors back, so Claude keeps
#     working to fix the build before handing control back to you.
#
# Loop guard:
#   When Claude is already continuing *because* of this hook, Claude Code sets
#   `stop_hook_active: true`. We detect that and DO NOT block again, otherwise
#   a persistently failing build would loop forever.
#
# Requires: jq, maven, a JDK on PATH.

set -uo pipefail

# Heavier than `compile` is fine here since it runs once per turn.
# Override by exporting MVN_GOALS before the session, e.g.:
#   export MVN_GOALS="-q -B verify"
#   export MVN_GOALS="-q -B clean install"   # heaviest; full clean + tests + package
MVN_GOALS="${MVN_GOALS:--q -B test}"

input=$(cat)

# Loop guard: if we're already inside a stop-hook-driven continuation, don't
# block again — just exit cleanly so the agent can stop.
active=$(printf '%s' "$input" | jq -r '.stop_hook_active // false' 2>/dev/null)
[ "$active" = "true" ] && exit 0

# Resolve the project root. Prefer Claude Code's env var; fall back to cwd.
root="${CLAUDE_PROJECT_DIR:-$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)}"
[ -n "$root" ] || root="$(pwd)"
[ -f "$root/pom.xml" ] || exit 0   # not a maven project — do nothing.

# Run the build. $MVN_GOALS is intentionally unquoted so the flags split.
# shellcheck disable=SC2086
out=$(cd "$root" && mvn $MVN_GOALS 2>&1)
status=$?

# Success → say nothing.
[ "$status" -eq 0 ] && exit 0

# Failure → feed back only the errors/failures, truncated, and block the stop.
{
  echo "Build FAILED (mvn $MVN_GOALS) — fix before finishing this task."
  echo "--- errors / test failures (truncated) ---"
  printf '%s\n' "$out" | grep -E '\[ERROR\]|FAIL|\.java:\[|Tests run:' | head -n 50
  echo "--- resolve the above, then stop ---"
} >&2

exit 2
