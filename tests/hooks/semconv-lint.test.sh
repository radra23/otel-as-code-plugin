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

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
