#!/usr/bin/env bash
# tests/hooks/collector-cardinality-contract.test.sh
# Guards the #37 contract: /otel-collector's high-cardinality delete_key list must be driven by a
# TYPED field the scanner actually emits (`derived.highCardinalityAttributes`), not by filtering
# conformanceIssues on a `severity: "cardinality"` value that no producer ever writes (which
# silently matched nothing, leaving only the four generic template identifiers protected).
set -uo pipefail
cd "$(dirname "$0")/../.."
pass=0; fail=0

COLLECTOR="commands/otel-collector.md"
SCANNER="agents/repo-context-scanner.md"

# 1. the collector reads the typed field
if grep -q "derived.highCardinalityAttributes" "$COLLECTOR"; then
  echo "PASS: /otel-collector reads derived.highCardinalityAttributes"; pass=$((pass+1))
else
  echo "FAIL: /otel-collector no longer reads derived.highCardinalityAttributes (#37)"; fail=$((fail+1))
fi

# 2. the scanner emits that field (same spelling — this is the producer↔consumer link that drifted)
if grep -q "highCardinalityAttributes" "$SCANNER"; then
  echo "PASS: scanner emits highCardinalityAttributes"; pass=$((pass+1))
else
  echo "FAIL: scanner does not emit highCardinalityAttributes — producer/consumer drift (#37)"; fail=$((fail+1))
fi
# (Reverting to the old severity filter necessarily drops the derived.highCardinalityAttributes
#  read, so check 1 already catches that regression — no brittle "severity=cardinality" grep here,
#  which would false-fire on the docs' own do-NOT guidance.)

echo ""
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
