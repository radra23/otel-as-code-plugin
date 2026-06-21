#!/usr/bin/env bash
# tests/hooks/session-summary.test.sh
# The SessionEnd summary must emit a bullet for EVERY otel file it counts — the set of
# files that trip the summary (is_otel_path) must match the set the output loop renders.
set -euo pipefail

HOOK="$(cd "$(dirname "$0")/../.." && pwd)/hooks/session-summary.sh"
PASS=0
FAIL=0

# Run the hook inside a throwaway git repo containing the given changed (untracked) files.
run_with() {
  local tmp; tmp=$(mktemp -d)
  ( cd "$tmp" && git init -q && git config user.email t@t.t && git config user.name t )
  local f
  for f in "$@"; do mkdir -p "$tmp/$(dirname "$f")"; echo "x" > "$tmp/$f"; done
  ( cd "$tmp" && bash "$HOOK" )
  rm -rf "$tmp"
}

assert_bullet() {  # name, file-that-must-appear-in-a-bullet, changed-files...
  local name="$1"; local needle="$2"; shift 2
  local out; out=$(run_with "$@")
  # A bullet for the file must exist (line starting with "- " and mentioning the file).
  if echo "$out" | grep -q "^- .*$needle"; then
    echo "PASS: $name"; PASS=$((PASS+1))
  else
    echo "FAIL: $name — counted but no bullet for '$needle'"
    echo "Output: $out"; FAIL=$((FAIL+1))
  fi
}

# Test 1: a generated bootstrap file → bullet (baseline behavior)
assert_bullet "tracing.js gets a bullet" "tracing.js" "src/tracing.js"

# Test 2: telemetry.js is counted by is_otel_path but had no output case → must get a bullet
assert_bullet "telemetry.js gets a bullet" "telemetry.js" "telemetry.js"

# Test 3: opentelemetry.js likewise must get a bullet
assert_bullet "opentelemetry.js gets a bullet" "opentelemetry.js" "app/opentelemetry.js"

# Test 4: no otel files changed → no summary at all
OUT=$(run_with "README.md" "src/index.js")
if [ -z "$OUT" ]; then
  echo "PASS: no summary when nothing otel changed"; PASS=$((PASS+1))
else
  echo "FAIL: produced output with no otel changes"; echo "Output: $OUT"; FAIL=$((FAIL+1))
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
