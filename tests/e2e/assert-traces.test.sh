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

# --expect-span: a span-level attribute must be present on some span of the service
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
TMP="$tmp" python3 - <<'PY'
import json, os
d = json.load(open("fixtures/jaeger-ok.json"))
d["data"][0]["spans"][0]["tags"] = [{"key": "http.route", "type": "string", "value": "/checkout"}]
json.dump(d, open(os.environ["TMP"] + "/ok.json", "w"))
d["data"][0]["spans"][0]["tags"] = []
json.dump(d, open(os.environ["TMP"] + "/missing.json", "w"))
PY
check "span attr present passes" \
  'bash assert-traces.sh --traces-json $tmp/ok.json --service checkout-api --expect service.name=checkout-api --expect-span http.route=/checkout >/dev/null'
check "span attr absent fails (route-less server span)" \
  '! bash assert-traces.sh --traces-json $tmp/missing.json --service checkout-api --expect service.name=checkout-api --expect-span http.route=/checkout >/dev/null'
check "span attr with the wrong value fails" \
  '! bash assert-traces.sh --traces-json $tmp/ok.json --service checkout-api --expect service.name=checkout-api --expect-span http.route=/other >/dev/null'
check "no --expect-span keeps the old behaviour" \
  'bash assert-traces.sh --traces-json $tmp/missing.json --service checkout-api --expect service.name=checkout-api >/dev/null'

echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
