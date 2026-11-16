#!/usr/bin/env bash
# tests/e2e/assert-metrics.test.sh: offline test of assert-metrics.sh parsing logic.
set -uo pipefail
cd "$(dirname "$0")"
pass=0; fail=0
check() { if eval "$2"; then echo "PASS: $1"; pass=$((pass+1)); else echo "FAIL: $1"; fail=$((fail+1)); fi; }
am() { bash assert-metrics.sh --metrics-json fixtures/otlp-metrics-ok.json "$@"; }

check "a service with a runtime metric passes, and a non-JSON line is skipped" \
  'am --service checkout-api --expect-prefix "nodejs." | grep -q "^OK: checkout-api emitted 1 runtime metric"'
check "any one of several prefixes is enough" \
  'am --service checkout-api --expect-prefix "jvm.,v8js." >/dev/null'
check "a service that sends only request metrics fails, and the failure lists what it sent" \
  'out=$(am --service inventory-api --expect-prefix "process.,cpython." 2>&1); [ $? -eq 1 ] && echo "$out" | grep -q "it sent: http.server.duration"'
check "another service's runtime metrics do not count" \
  '! am --service inventory-api --expect-prefix "nodejs." >/dev/null 2>&1'
check "an absent service fails as absent" \
  'out=$(am --service ghost-api --expect-prefix "nodejs." 2>&1); [ $? -eq 1 ] && echo "$out" | grep -q "no metrics at all"'
check "a prefix is a prefix, not a substring" \
  '! am --service checkout-api --expect-prefix "eventloop" >/dev/null 2>&1'
check "missing arguments are a usage error (exit 2)" \
  'am --service checkout-api >/dev/null 2>&1; [ $? -eq 2 ]'

echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
