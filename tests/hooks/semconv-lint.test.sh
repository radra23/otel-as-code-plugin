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

# All three carry a real OTel import line: the #138 content gate looks for one (or
# ActivitySource/Meter( for .NET's import-free style), so a bare snippet with no import is
# invisible to the hook by design — same as real code would be if it never touched the OTel API.
OTEL_IMPORT="const { trace } = require('@opentelemetry/api');"

# severe-only file (deprecated http.method — Rule 2)
SEV=$(mktemp -d); printf "%s\nfunction h(span){ span.setAttribute('http.method','GET'); }\n" "$OTEL_IMPORT" > "$SEV/tracing.js"
# warn-only file (SimpleSpanProcessor — Rule 6; no severe rule fires)
WRN=$(mktemp -d); printf "%s\nconst p = new SimpleSpanProcessor(exporter);\n" "$OTEL_IMPORT" > "$WRN/tracing.js"
# clean OTel file (current attribute names)
CLN=$(mktemp -d); printf "%s\nfunction h(span){ span.setAttribute('http.request.method','POST'); }\n" "$OTEL_IMPORT" > "$CLN/tracing.js"

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

# Test 11: no python + strict → fail closed (exit 2) — can't uphold the strict block guarantee.
set +e; emit "$SEV/tracing.js" | OTEL_HOOK_PYTHON= OTEL_STRICT=1 bash "$HOOK" >/dev/null 2>&1; RC=$?; set -e
check_rc "no-python + strict -> exit 2 (fail closed)" 2 "$RC"

# Test 12: no python + advisory (default) → skip quietly (exit 0) — advisory lint can't run.
set +e; emit "$SEV/tracing.js" | OTEL_HOOK_PYTHON= bash "$HOOK" >/dev/null 2>&1; RC=$?; set -e
check_rc "no-python + advisory -> exit 0 (skip)" 0 "$RC"

# Test 13/14 (#54): interpreter RESOLVES but does not RUN (Windows `python3` alias stub) — same
# guarantee as no-python: strict fails closed (exit 2), advisory skips (exit 0). Before the fix
# the naive `command -v` picked the stub, the parse produced nothing, and strict never blocked.
STUBDIR=$(mktemp -d); printf '#!/bin/sh\nexit 9\n' > "$STUBDIR/py-stub"; chmod +x "$STUBDIR/py-stub"
set +e; emit "$SEV/tracing.js" | OTEL_HOOK_PYTHON="$STUBDIR/py-stub" OTEL_STRICT=1 bash "$HOOK" >/dev/null 2>&1; RC=$?; set -e
check_rc "stub interpreter + strict -> exit 2 (fail closed)" 2 "$RC"
set +e; emit "$SEV/tracing.js" | OTEL_HOOK_PYTHON="$STUBDIR/py-stub" bash "$HOOK" >/dev/null 2>&1; RC=$?; set -e
check_rc "stub interpreter + advisory -> exit 0 (skip)" 0 "$RC"
rm -rf "$STUBDIR"

rm -rf "$SEV" "$WRN" "$CLN"

# --- #138: content gate (basename gate is gone) --------------------------------------------------
GATEDIR=$(mktemp -d)

# Test 15: a file with an OTel-API-referencing name NOT matched by the old basename gate
# (tracing/telemetry/instrumentation/opentelemetry) still gets linted, because it imports the API.
printf "const { trace } = require('@opentelemetry/api');\nfunction h(span){ span.setAttribute('http.method','GET'); }\n" \
  > "$GATEDIR/handlers.js"
OUTPUT=$(run_lint "$GATEDIR/handlers.js")
if echo "$OUTPUT" | grep -q "http.method"; then
  echo "PASS: #138 a non-tracing/telemetry-named file that imports the OTel API is linted (basename gate removed)"
  PASS=$((PASS+1))
else
  echo "FAIL: #138 a non-tracing/telemetry-named file that imports the OTel API was NOT linted"
  FAIL=$((FAIL+1))
fi

# Test 16: a .NET-style file using ActivitySource — never mentions "OpenTelemetry" by name at all
# (System.Diagnostics.ActivitySource is a .NET built-in type the OTel SDK listens to) — must still
# be linted via the ActivitySource/Meter fallback marker, not just the "opentelemetry" substring.
printf 'using System.Diagnostics;\nvar source = new ActivitySource("svc");\nactivity.SetTag("http.method", "GET");\n' \
  > "$GATEDIR/InstrumentsFactory.cs"
OUTPUT=$(run_lint "$GATEDIR/InstrumentsFactory.cs")
if echo "$OUTPUT" | grep -q "http.method"; then
  echo "PASS: #138 a .NET file using ActivitySource with no literal 'OpenTelemetry' text is still linted"
  PASS=$((PASS+1))
else
  echo "FAIL: #138 a .NET ActivitySource file with no 'OpenTelemetry' text was NOT linted"
  FAIL=$((FAIL+1))
fi

# Test 17: a file with none of the OTel markers at all → zero output, still not linted (the gate
# narrows, it doesn't disappear — an arbitrary file must not be scanned).
printf "function h(x){ return x.setAttribute('http.method', 'GET'); }\n" > "$GATEDIR/unrelated.js"
OUTPUT=$(run_lint "$GATEDIR/unrelated.js")
if [ -z "$OUTPUT" ]; then
  echo "PASS: #138 a file with no OTel marker at all produces no output (gate still excludes non-OTel code)"
  PASS=$((PASS+1))
else
  echo "FAIL: #138 a file with no OTel marker at all was linted anyway"
  echo "Output: $OUTPUT"
  FAIL=$((FAIL+1))
fi

# --- #138: language-aware attribute-setter matching (gate 2) -------------------------------------

# Test 18: .NET's activity.SetTag(...) triggers Rule 1 (service.name as span attribute) — the old
# hook only matched JS/Java's setAttribute( spelling.
printf 'using OpenTelemetry;\nactivity.SetTag("service.name", "svc");\n' > "$GATEDIR/dotnet-rule1.cs"
OUTPUT=$(run_lint "$GATEDIR/dotnet-rule1.cs")
if echo "$OUTPUT" | grep -q "Resource attributes, not span attributes"; then
  echo "PASS: #138 .NET's SetTag( is recognized as a span-attribute setter (Rule 1)"
  PASS=$((PASS+1))
else
  echo "FAIL: #138 .NET's SetTag( was not recognized (Rule 1)"
  FAIL=$((FAIL+1))
fi

# Test 19: Go's attribute.String(...) triggers Rule 5 (missing namespace prefix) — Go builds a
# KeyValue via the attribute package rather than passing the key straight to a setter call.
printf 'import "go.opentelemetry.io/otel/attribute"\nspan.SetAttributes(attribute.String("orderId", id))\n' \
  > "$GATEDIR/go-rule5.go"
OUTPUT=$(run_lint "$GATEDIR/go-rule5.go")
if echo "$OUTPUT" | grep -qi "namespace prefix"; then
  echo "PASS: #138 Go's attribute.String( is recognized as an attribute setter (Rule 5)"
  PASS=$((PASS+1))
else
  echo "FAIL: #138 Go's attribute.String( was not recognized (Rule 5)"
  FAIL=$((FAIL+1))
fi

# Test 20: Python's span.set_attribute(...) with the dotted canonical form triggers Rule 7.
printf "from opentelemetry import trace\nspan.set_attribute('user.id', uid)\n" > "$GATEDIR/python-rule7.py"
OUTPUT=$(run_lint "$GATEDIR/python-rule7.py")
if echo "$OUTPUT" | grep -q "High-cardinality attribute 'user.id' detected as a span attribute"; then
  echo "PASS: #138 the dotted canonical form (user.id) is matched by Rule 7, not just camelCase/snake_case"
  PASS=$((PASS+1))
else
  echo "FAIL: #138 the dotted canonical form (user.id) was not matched by Rule 7"
  echo "Output: $OUTPUT"
  FAIL=$((FAIL+1))
fi

# --- #138: metric-dimension rule (gate 3, new Rule 8 — error tier, not warning) -------------------

# Test 21: a counter's .add() call carrying a high-cardinality dimension is Rule 8 (severe/error),
# with the metric-specific "remove the tag" remediation — not Rule 7's "move to events" text.
printf "const { metrics } = require('@opentelemetry/api');\nconst counter = meter.createCounter('msgs');\ncounter.add(1, { 'user.id': uid });\n" \
  > "$GATEDIR/metric-dimension.js"
OUTPUT=$(run_lint "$GATEDIR/metric-dimension.js")
if echo "$OUTPUT" | grep -q "METRIC dimension" && echo "$OUTPUT" | grep -q "Remove the tag entirely"; then
  echo "PASS: #138 a high-cardinality metric dimension is caught (Rule 8) with the remove-the-tag remediation"
  PASS=$((PASS+1))
else
  echo "FAIL: #138 a high-cardinality metric dimension was not caught with the correct remediation"
  echo "Output: $OUTPUT"
  FAIL=$((FAIL+1))
fi

# Test 22: strict mode blocks on the metric-dimension violation (it's severe, same as Rules 1-4).
set +e; emit "$GATEDIR/metric-dimension.js" | OTEL_STRICT=1 bash "$HOOK" >/dev/null 2>&1; RC=$?; set -e
check_rc "#138 strict mode blocks on a metric-dimension violation (Rule 8 is severe)" 2 "$RC"

# Test 23: the SAME high-cardinality identifier as a plain SPAN attribute (no instrument
# constructor anywhere in the file) stays Rule 7 (warning) — Rule 8 must not fire on every file
# that merely contains a high-cardinality literal, only ones that actually construct an instrument.
printf "const { trace } = require('@opentelemetry/api');\nspan.setAttribute('user.id', uid);\n" \
  > "$GATEDIR/span-only.js"
OUTPUT=$(run_lint "$GATEDIR/span-only.js")
if echo "$OUTPUT" | grep -q "detected as a span attribute" && ! echo "$OUTPUT" | grep -q "METRIC dimension"; then
  echo "PASS: #138 a high-cardinality span attribute (no instrument in the file) stays Rule 7, not Rule 8"
  PASS=$((PASS+1))
else
  echo "FAIL: #138 Rule 7/Rule 8 did not stay distinct for a span-only high-cardinality attribute"
  echo "Output: $OUTPUT"
  FAIL=$((FAIL+1))
fi

rm -rf "$GATEDIR"

# Test 24: the hook's DOTTED_HIGH_CARD extraction reads semconv-discipline's canonical list
# directly (single source of truth, #138 gate 4) rather than a hardcoded second copy. The hook
# falls back to an identical hardcoded default if extraction ever fails, which would make Test 20
# pass silently even if the anchor text drifted — assert the extraction itself succeeds, not just
# that the (possibly-fallback) end behavior happens to match.
EXTRACTED=$(grep -A2 "hook's extraction depends on its shape" skills/semconv-discipline/SKILL.md 2>/dev/null | \
  tail -1 | grep -oE '`[a-z_]+\.[a-z_]+`' | tr -d '`' | tr '\n' ' ')
if [ "$EXTRACTED" = "user.id session.id request.id order.id " ]; then
  echo "PASS: #138 semconv-lint's DOTTED_HIGH_CARD extraction anchor still resolves against the skill file"
  PASS=$((PASS+1))
else
  echo "FAIL: #138 the extraction anchor no longer resolves to the canonical list (hook silently fell back to its hardcoded default)"
  echo "Got: '$EXTRACTED'"
  FAIL=$((FAIL+1))
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
