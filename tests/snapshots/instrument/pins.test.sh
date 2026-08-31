#!/usr/bin/env bash
# Guards: golden bootstraps stay syntactically valid AND their pins match
# agents/instrumentation-gen.md (the single source for OTel SDK versions).
set -uo pipefail
cd "$(dirname "$0")/../../.."   # repo root
pass=0; fail=0
check() { if eval "$2"; then echo "PASS: $1"; pass=$((pass+1)); else echo "FAIL: $1"; fail=$((fail+1)); fi; }

# pins_match <package.json path> — every "@opentelemetry/pkg": "version" pair captured
# from the given package.json must appear verbatim (full name+version pair, NOT just
# the package name) as a substring of agents/instrumentation-gen.md. Prints
# "  drift: <pair>" per miss; returns nonzero if any pair is missing.
pins_match() {
  local target="$1" miss=0 pair
  while IFS= read -r pair; do
    grep -qF "$pair" agents/instrumentation-gen.md || { echo "  drift: $pair"; miss=1; }
  done < <(grep -oE "\"@opentelemetry/[^\"]+\": \"[^\"]+\"" "$target")
  [ "$miss" -eq 0 ]
}

check "node bootstrap parses" 'node --check tests/snapshots/instrument/nodejs/tracing.js'
check "python bootstrap compiles" 'python3 -m py_compile tests/snapshots/instrument/python/tracing.py'
# every OTel pin (full name+version pair) in the golden package.json must appear in instrumentation-gen.md
check "node pins match generator" 'pins_match tests/snapshots/instrument/nodejs/package.json'

# Teeth check: proves pins_match actually compares versions, not just package names.
# Injects a version-only drift (^0.221.0 -> ^9.999.0) into a throwaway copy of the golden
# package.json and asserts pins_match correctly reports failure on it. Without this,
# a name-only check (the bug this fix addresses) would silently pass here too.
check "pin guard catches version drift (teeth check)" '
  tmp=$(mktemp -d)
  sed -E "s/(\"@opentelemetry\/sdk-node\": \")\^0\.221\.0\"/\1^9.999.0\"/" tests/snapshots/instrument/nodejs/package.json > "$tmp/package.json"
  drift_injected=0
  grep -qF "\"@opentelemetry/sdk-node\": \"^9.999.0\"" "$tmp/package.json" && drift_injected=1
  guard_caught_drift=0
  if [ "$drift_injected" -eq 1 ] && ! pins_match "$tmp/package.json" >/dev/null; then
    guard_caught_drift=1
  fi
  rm -rf "$tmp"
  [ "$drift_injected" -eq 1 ] && [ "$guard_caught_drift" -eq 1 ]'

# Java golden agent config: required OTEL_* keys present + gRPC protocol (paired with :4317
# throughout the plugin; the agent's own default is http/protobuf:4318, so grpc must be explicit).
check "java golden otel-java.env has required keys + grpc" '
  f=tests/snapshots/instrument/java/otel-java.env
  grep -q "^OTEL_SERVICE_NAME=" "$f" \
    && grep -q "deployment.environment.name=" "$f" \
    && grep -q "^OTEL_EXPORTER_OTLP_ENDPOINT=" "$f" \
    && grep -q "^OTEL_EXPORTER_OTLP_PROTOCOL=grpc$" "$f"'

# The pinned OTel Java agent version the e2e harness downloads (run.sh) must match the
# generator doc (agents/instrumentation-gen.md), so the two never drift apart.
check "java agent version pin matches generator" '
  v=$(grep -oE "OTEL_JAVA_AGENT_VERSION=[0-9.]+" tests/e2e/run.sh | head -1 | cut -d= -f2)
  [ -n "$v" ] && grep -qF "$v" agents/instrumentation-gen.md'

echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
