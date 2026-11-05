#!/usr/bin/env bash
# tests/hooks/auditor-guidance-gaps.test.sh
# Locks #227, four gaps in brownfield-auditor's guidance:
#   1. No rule on whether an installed package's own source (node_modules / site-packages) may be
#      cited as evidence of what it emits, stronger than inferring behavior from a version number.
#   2. PII dimension (§7) had no canonical personal-data attribute list, unlike the cardinality
#      dimension's canonical high-cardinality identifier list in the same skill file.
#   3. language-maturity's per-language "Auto" row read as covering every bundled instrumentation
#      package at that same maturity, with no instruction to check a specific package that pins
#      below its siblings (the .NET EntityFrameworkCore case was the only named exception).
#   4. The SDK-health table had no row for the serverless freeze/thaw risk: a periodic batch
#      flush cannot be relied on between invocations.
set -uo pipefail
cd "$(dirname "$0")/../.."
pass=0; fail=0
check() { if eval "$2"; then echo "PASS: $1"; pass=$((pass+1)); else echo "FAIL: $1"; fail=$((fail+1)); fi; }

AUDITOR="agents/brownfield-auditor.md"
SEMCONV="skills/semconv-discipline/SKILL.md"
MATURITY="skills/language-maturity/SKILL.md"

# --- item 1: node_modules / installed-package source as evidence ---
check "auditor says reading an installed package's own source outranks a version-based heuristic" \
  'grep -qF "Reading an installed package'"'"'s own source is stronger evidence than its version number alone" "$AUDITOR"'
check "auditor distinguishes this (readable JS/Python source) from the #215 DLL case (binary, out of reach)" \
  'grep -qF "ships plain-text source you CAN" "$AUDITOR" && grep -qF "(#215" "$AUDITOR"'
check "auditor warns a zero-match grep against minified/bundled output is not evidence of absence" \
  'grep -qiF "minified/bundled output can" "$AUDITOR" \
   && grep -qF "fall back to the version-based heuristic" "$AUDITOR"'

# --- item 2: canonical PII attribute-pattern list ---
check "semconv-discipline defines a canonical personal-data attribute pattern section" \
  'grep -qF "## Canonical Personal-Data Attribute Patterns (#227)" "$SEMCONV"'
check "the PII section gives both a by-name list and an independent by-value-shape list" \
  'grep -qF "**By attribute name**" "$SEMCONV" && grep -qF "**By value shape**" "$SEMCONV" \
   && grep -qF "matched as an exact key or as the attribute'"'"'s final dotted segment" "$SEMCONV"'
check "the by-name list includes the common personal-data attribute keys" \
  'grep -qF "\`user.email\`, \`user.name\`, \`user.full_name\`, \`user.phone\`" "$SEMCONV"'
check "auditor dimension 7 cross-references the canonical list instead of inventing examples from memory" \
  'grep -qF "Match against the canonical list, not memory (#227)" "$AUDITOR" \
   && grep -qF "Canonical" "$AUDITOR" && grep -qF "Attribute Patterns" "$AUDITOR"'
check "teeth: the new PII section does not disturb semconv-lint's 2-line cardinality-list extraction" \
  '[ "$(grep -A2 "hook'"'"'s extraction depends on its shape" "$SEMCONV" | tail -1)" \
     = "\`user.id\`, \`session.id\`, \`request.id\`, \`order.id\`." ]'

# --- item 3: per-package auto-instrumentation maturity caveat ---
check "language-maturity explains the Auto row is the mechanism's maturity, not every bundled package's" \
  'grep -qF "## The \"Auto\" row is the mechanism'"'"'s maturity, not every bundled package'"'"'s (#227)" "$MATURITY"'
check "it generalizes the .NET EntityFrameworkCore exception as a pattern that can recur anywhere" \
  'grep -qiF "the same shape can recur in any ecosystem" "$MATURITY"'
check "it tells the reader to check a specific installed package rather than trusting the blanket row" \
  'grep -qiF "without checking" "$MATURITY" && grep -qF "report it as an \`MB\` finding" "$MATURITY"'

# --- item 4: serverless row in SDK health ---
check "auditor adds a serverless flush-cannot-be-relied-on check to SDK health (dimension 4)" \
  'grep -qF "Serverless host: a periodic batch flush cannot be relied on (#227)" "$AUDITOR"'
check "it explains the freeze/thaw mechanism, not just asserts a rule" \
  'grep -qiF "execution environment can freeze between" "$AUDITOR" \
   && grep -qiF "cannot fire" "$AUDITOR"'
check "it ties to the already-generated per-invocation flush pattern (CLI shape) rather than inventing a new one" \
  'grep -qF "flush every invocation, not only on" "$AUDITOR"'
check "it classifies the gap as live, not latent, since it recurs on normal operation" \
  'grep -qiF "is a live finding (data loss in normal operation), not a" "$AUDITOR"'

echo
echo "auditor-guidance-gaps: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
