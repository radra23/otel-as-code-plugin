#!/usr/bin/env bash
# tests/e2e/assert-logs.test.sh — offline test of assert-logs.sh parsing logic.
set -uo pipefail
cd "$(dirname "$0")"
pass=0; fail=0
check() { if eval "$2"; then echo "PASS: $1"; pass=$((pass+1)); else echo "FAIL: $1"; fail=$((fail+1)); fi; }

# a matching service + body substring across the JSON-Lines file -> exit 0
check "ok fixture passes (service + body)" \
  'bash assert-logs.sh --logs-json fixtures/otlp-logs-ok.json --service inventory-api --expect-body "reserved sku" >/dev/null'
# service present, body substring absent -> non-zero
check "wrong body substring fails" \
  '! bash assert-logs.sh --logs-json fixtures/otlp-logs-ok.json --service inventory-api --expect-body "nope-not-here" >/dev/null'
# service absent -> non-zero (proves we do not match the unrelated checkout-api record)
check "absent service fails" \
  '! bash assert-logs.sh --logs-json fixtures/otlp-logs-ok.json --service ghost-api --expect-body "reserved sku" >/dev/null'
# service match with no body constraint -> exit 0
check "service-only match passes" \
  'bash assert-logs.sh --logs-json fixtures/otlp-logs-ok.json --service inventory-api >/dev/null'

echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
