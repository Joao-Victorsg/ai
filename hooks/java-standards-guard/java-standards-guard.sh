#!/usr/bin/env bash
#
# java-standards-guard.sh
# PreToolUse hook for Claude Code — Spring Boot 4 / Java 25 projects.
#
# Turns the always-on `java-standards` rule from advisory into ENFORCED.
# Before Claude writes a .java file, this inspects the NEW content and blocks
# the edit (exit 2) if it introduces a pattern the rule explicitly forbids,
# feeding back a precise reason so Claude rewrites it correctly.
#
# Design notes:
#   - PreToolUse runs BEFORE the write, so a block prevents the bad code from
#     ever hitting disk (cheaper than catching it at compile/build time).
#   - We only block HIGH-CONFIDENCE, unambiguous violations to avoid false
#     positives. Softer/contextual rules (records-only DTOs, dependency
#     inversion, pattern-matching-over-instanceof) are left to the reviewer
#     agent and the build hook, not a regex gate.
#   - Token cost is ~0: silent unless it blocks, and a block is a few lines.
#
# Banned (hard block), per rules/java-standards.md:
#   - @Data                              (Lombok @Data is forbidden)
#   - MapStruct / external mappers       (org.mapstruct, @Mapper)
#   - System.out/err.println / printStackTrace   (use SLF4J, see log skill)
#   - Generic control-flow exceptions thrown: `throw new RuntimeException(` /
#     `throw new IllegalStateException(`  (use named domain exceptions)
#
# Requires: jq.

set -uo pipefail

input=$(cat)

tool=$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null)
file=$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.path // empty' 2>/dev/null)

case "$file" in
  *.java) ;;
  *) exit 0 ;;
esac

# Pull the text that is about to be written. Covers Write (content),
# Edit (new_string), and MultiEdit (all edits[].new_string).
content=$(printf '%s' "$input" | jq -r '
  .tool_input.content
  // .tool_input.new_string
  // ([.tool_input.edits[]?.new_string] | join("\n"))
  // empty' 2>/dev/null)

[ -n "$content" ] || exit 0

violations=()

grep -Eq '(^|[^A-Za-z])@Data([^A-Za-z]|$)' <<<"$content" \
  && violations+=("@Data is forbidden. Use @RequiredArgsConstructor/@Builder; for JPA entities write explicit equals/hashCode by business id.")

grep -Eq 'org\.mapstruct|@Mapper\b' <<<"$content" \
  && violations+=("MapStruct / external mappers are forbidden. The transformation belongs to the created object (e.g. a static fromDomain factory).")

grep -Eq 'System\.(out|err)\.print|\.printStackTrace\(' <<<"$content" \
  && violations+=("No System.out/err or printStackTrace. Use structured SLF4J logging (see the spring-java-log-standardization skill).")

grep -Eq 'throw[[:space:]]+new[[:space:]]+(RuntimeException|IllegalStateException|IllegalArgumentException)\(' <<<"$content" \
  && violations+=("Don't throw generic exceptions for business flow. Use a named domain exception (e.g. OrderAlreadyConfirmedException) or a sealed result type.")

# No violations → allow the write silently.
[ ${#violations[@]} -eq 0 ] && exit 0

{
  echo "Blocked $tool on $file — java-standards violation(s):"
  for v in "${violations[@]}"; do
    echo "  - $v"
  done
  echo "Rewrite to comply with rules/java-standards.md, then retry."
} >&2

exit 2
