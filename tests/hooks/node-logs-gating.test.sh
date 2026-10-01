#!/usr/bin/env bash
# tests/hooks/node-logs-gating.test.sh
# Node.js logs are Development-level in OpenTelemetry JS (skills/language-maturity), so the default
# golden bootstrap must not turn them on: NodeSDK builds the logs pipeline from OTEL_LOGS_EXPORTER
# alone. This runs the golden's real exporter-selection block under node, in each env shape, and
# checks the defaults it leaves behind. The --experimental golden must still default logs on.
set -uo pipefail
cd "$(dirname "$0")/../.."
pass=0; fail=0
DIR="tests/snapshots/instrument/nodejs"

# Run only the exporter-selection block (hasEndpoint .. the protocol default) so no OTel package is
# needed; print the three exporter vars it settles on.
selection() {  # $1 = golden file; remaining args = env assignments
  local file="$1"; shift
  local block
  block=$(sed -n '/^const hasEndpoint = /,/^\/\/ This plugin standardizes on OTLP/p' "$file")
  env -i PATH="$PATH" "$@" node -e "$block
console.log([process.env.OTEL_TRACES_EXPORTER, process.env.OTEL_METRICS_EXPORTER, process.env.OTEL_LOGS_EXPORTER].join(' '));"
}

check() {  # name, expected, actual
  if [ "$2" = "$3" ]; then echo "PASS: $1"; pass=$((pass+1))
  else echo "FAIL: $1 — expected '$2', got '$3'"; fail=$((fail+1)); fi
}

# node ships on the CI runner; a missing node must fail loudly, not pass by skipping.
if ! command -v node >/dev/null; then echo "FAIL: node not installed"; exit 1; fi

E=OTEL_EXPORTER_OTLP_ENDPOINT=http://collector:4317
check "default: endpoint set → traces+metrics otlp, logs stay none" \
  "otlp otlp none" "$(selection "$DIR/tracing.js" "$E")"
check "default: no endpoint → everything none" \
  "none none none" "$(selection "$DIR/tracing.js")"
check "default: explicit OTEL_LOGS_EXPORTER=otlp is the user's opt-in and is left alone" \
  "otlp otlp otlp" "$(selection "$DIR/tracing.js" "$E" OTEL_LOGS_EXPORTER=otlp)"
check "--experimental: endpoint set → logs default to otlp too" \
  "otlp otlp otlp" "$(selection "$DIR/tracing.experimental.js" "$E")"
check "--experimental: no endpoint → everything none" \
  "none none none" "$(selection "$DIR/tracing.experimental.js")"

# The generator template carries the same block as the golden (catches one being edited alone).
if grep -qF "const LOGS_ON_BY_DEFAULT = false;" agents/instrumentation-gen.md \
   && grep -qF "const LOGS_ON_BY_DEFAULT = true;" agents/instrumentation-gen.md; then
  echo "PASS: generator template has both the default and the --experimental logs line"; pass=$((pass+1))
else
  echo "FAIL: generator template lost the LOGS_ON_BY_DEFAULT gate"; fail=$((fail+1))
fi
if grep -qE "^\| Logs +\| Development +\| \`@opentelemetry/sdk-logs\`" skills/language-maturity/SKILL.md; then
  echo "PASS: language-maturity lists Node.js logs as Development"; pass=$((pass+1))
else
  echo "FAIL: language-maturity Node.js logs row is not Development"; fail=$((fail+1))
fi

echo ""
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
