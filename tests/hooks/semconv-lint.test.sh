#!/usr/bin/env bash
# tests/hooks/semconv-lint.test.sh
# Tests that the semconv-lint hook detects the 3 seeded violations in the brownfield fixture
# and produces ZERO warnings on the greenfield fixture.
set -euo pipefail

HOOK="hooks/semconv-lint.sh"
PASS=0
FAIL=0

run_lint() {
  local file="$1"
  echo "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$file\"}}" | bash "$HOOK" 2>&1
}

# Test 1: Brownfield fixture → detect 'service.name' as span attribute
OUTPUT=$(run_lint "fixtures/nodejs-brownfield/tracing.js")
if echo "$OUTPUT" | grep -q "service.name"; then
  echo "PASS: detects service.name violation"
  PASS=$((PASS+1))
else
  echo "FAIL: did not detect service.name violation"
  echo "Output was: $OUTPUT"
  FAIL=$((FAIL+1))
fi

# Test 2: Brownfield fixture → detect deprecated 'http.method'
OUTPUT=$(run_lint "fixtures/nodejs-brownfield/tracing.js")
if echo "$OUTPUT" | grep -q "http.method\|http\.request\.method"; then
  echo "PASS: detects http.method deprecation"
  PASS=$((PASS+1))
else
  echo "FAIL: did not detect http.method deprecation"
  FAIL=$((FAIL+1))
fi

# Test 3: Brownfield fixture → detect un-namespaced 'orderId'
OUTPUT=$(run_lint "fixtures/nodejs-brownfield/tracing.js")
if echo "$OUTPUT" | grep -qi "orderId\|namespace\|prefix"; then
  echo "PASS: detects missing namespace prefix"
  PASS=$((PASS+1))
else
  echo "FAIL: did not detect missing namespace prefix"
  FAIL=$((FAIL+1))
fi

# Test 4: Greenfield fixture (no OTel code) → zero warnings
OUTPUT=$(run_lint "fixtures/nodejs-greenfield/index.js")
if ! echo "$OUTPUT" | grep -qi "warning\|violation\|deprecated"; then
  echo "PASS: no false positives on clean file"
  PASS=$((PASS+1))
else
  echo "FAIL: false positive on clean file"
  echo "Output: $OUTPUT"
  FAIL=$((FAIL+1))
fi

# Test 5: conformant OTel file using standard single-word key ('error') and a properly
# namespaced custom attribute → zero warnings (guards Rule 5 against false positives).
TMP=$(mktemp -d)
cat > "$TMP/tracing.js" <<'EOF'
function handle(span, orderId) {
  span.setAttribute('error', true);
  span.setAttribute('http.request.method', 'POST');
  span.setAttribute('com.myorg.order.id', orderId);
}
EOF
OUTPUT=$(run_lint "$TMP/tracing.js")
if ! echo "$OUTPUT" | grep -qi "warning\|namespace\|deprecated"; then
  echo "PASS: no false positive on conformant otel file"
  PASS=$((PASS+1))
else
  echo "FAIL: false positive on conformant otel file"
  echo "Output: $OUTPUT"
  FAIL=$((FAIL+1))
fi
rm -rf "$TMP"

# --- Strict mode (OTEL_STRICT=1 env or .claude/.otel-strict sentinel) ---
# Strict hard-blocks (exit 2) ONLY on severe violations (Rules 1-4: service.*-as-span +
# deprecated http.method/http.url/http.status_code). Heuristic/judgment rules (5-7) stay
# warn-only. Default (non-strict) behavior is unchanged: always exit 0.
emit() { echo "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$1\"}}"; }
check_rc() {  # name expected_rc actual_rc
  if [ "$2" -eq "$3" ]; then echo "PASS: $1"; PASS=$((PASS+1))
  else echo "FAIL: $1 (expected rc=$2, got $3)"; FAIL=$((FAIL+1)); fi
}

# severe-only file (deprecated http.method — Rule 2)
SEV=$(mktemp -d); printf "function h(span){ span.setAttribute('http.method','GET'); }\n" > "$SEV/tracing.js"
# warn-only file (SimpleSpanProcessor — Rule 6; no severe rule fires)
WRN=$(mktemp -d); printf "const p = new SimpleSpanProcessor(exporter);\n" > "$WRN/tracing.js"
# clean OTel file (current attribute names)
CLN=$(mktemp -d); printf "function h(span){ span.setAttribute('http.request.method','POST'); }\n" > "$CLN/tracing.js"

# Test 6: strict OFF + severe → exit 0 (default advisory behavior preserved)
set +e; emit "$SEV/tracing.js" | bash "$HOOK" >/dev/null 2>&1; RC=$?; set -e
check_rc "strict off + severe -> exit 0 (advisory unchanged)" 0 "$RC"

# Test 7: strict ON (OTEL_STRICT=1) + severe → exit 2 (blocked)
set +e; emit "$SEV/tracing.js" | OTEL_STRICT=1 bash "$HOOK" >/dev/null 2>&1; RC=$?; set -e
check_rc "strict on + severe -> exit 2 (blocked)" 2 "$RC"

# Test 8: strict ON + warn-only (no severe) → exit 0 (not blocked)
set +e; emit "$WRN/tracing.js" | OTEL_STRICT=1 bash "$HOOK" >/dev/null 2>&1; RC=$?; set -e
check_rc "strict on + warn-only -> exit 0 (not blocked)" 0 "$RC"

# Test 9: strict ON via .claude/.otel-strict sentinel + severe → exit 2
SENT=$(mktemp -d); mkdir -p "$SENT/.claude"; touch "$SENT/.claude/.otel-strict"
set +e; emit "$SEV/tracing.js" | CLAUDE_PROJECT_DIR="$SENT" bash "$HOOK" >/dev/null 2>&1; RC=$?; set -e
check_rc "strict via .otel-strict sentinel + severe -> exit 2" 2 "$RC"
rm -rf "$SENT"

# Test 10: strict ON + clean file → exit 0
set +e; emit "$CLN/tracing.js" | OTEL_STRICT=1 bash "$HOOK" >/dev/null 2>&1; RC=$?; set -e
check_rc "strict on + clean -> exit 0" 0 "$RC"

rm -rf "$SEV" "$WRN" "$CLN"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
