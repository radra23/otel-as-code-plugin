#!/usr/bin/env bash
# Guards: golden bootstraps stay syntactically valid AND their pins match
# agents/instrumentation-gen.md (the single source for OTel SDK versions).
set -uo pipefail
cd "$(dirname "$0")/../../.."   # repo root
pass=0; fail=0
check() { if eval "$2"; then echo "PASS: $1"; pass=$((pass+1)); else echo "FAIL: $1"; fail=$((fail+1)); fi; }

check "node bootstrap parses" 'node --check tests/snapshots/instrument/nodejs/tracing.js'
check "python bootstrap compiles" 'python3 -m py_compile tests/snapshots/instrument/python/tracing.py'
# every OTel pin in the golden package.json must appear in instrumentation-gen.md
check "node pins match generator" '
  miss=0
  while IFS= read -r line; do
    pkg=$(printf "%s" "$line" | sed -E "s/.*\"(@opentelemetry\/[^\"]+)\".*/\1/")
    grep -qF "\"$pkg\"" agents/instrumentation-gen.md || { echo "  drift: $pkg"; miss=1; }
  done < <(grep -oE "\"@opentelemetry/[^\"]+\": \"[^\"]+\"" tests/snapshots/instrument/nodejs/package.json)
  [ "$miss" -eq 0 ]'

echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
