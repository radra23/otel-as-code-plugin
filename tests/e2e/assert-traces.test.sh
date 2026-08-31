#!/usr/bin/env bash
# tests/e2e/assert-traces.test.sh — offline test of assert-traces.sh parsing logic.
set -uo pipefail
cd "$(dirname "$0")"
pass=0; fail=0
check() { if eval "$2"; then echo "PASS: $1"; pass=$((pass+1)); else echo "FAIL: $1"; fail=$((fail+1)); fi; }

# correct attrs -> exit 0
check "ok fixture passes" \
  'bash assert-traces.sh --traces-json fixtures/jaeger-ok.json --service checkout-api --expect service.name=checkout-api,service.version=1.4.2,service.namespace=storefront >/dev/null'
# missing version -> non-zero
check "missing service.version fails" \
  '! bash assert-traces.sh --traces-json fixtures/jaeger-missing-version.json --service checkout-api --expect service.version=1.4.2 >/dev/null'
# wrong service -> non-zero
check "absent service fails" \
  '! bash assert-traces.sh --traces-json fixtures/jaeger-ok.json --service nope --expect service.name=nope >/dev/null'

echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
