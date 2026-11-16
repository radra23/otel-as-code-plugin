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

# --expect-trace-id: the matching record must carry a real trace ID.
tdir=$(mktemp -d)
rec() { printf '{"resourceLogs":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"search-api"}}]},"scopeLogs":[{"logRecords":[{"body":{"stringValue":"search served"}%s}]}]}]}\n' "$1"; }
rec ',"traceId":"0af7651916cd43dd8448eb211c80319c","spanId":"b7ad6b7169203331"' > "$tdir/traced.json"
rec '' > "$tdir/untraced.json"
rec ',"traceId":"00000000000000000000000000000000"' > "$tdir/zero.json"
check "a record with a trace ID passes --expect-trace-id" \
  'bash assert-logs.sh --logs-json "$tdir/traced.json" --service search-api --expect-body "search served" --expect-trace-id >/dev/null'
check "a record with no trace ID fails --expect-trace-id, and passes without it" \
  'out=$(bash assert-logs.sh --logs-json "$tdir/untraced.json" --service search-api --expect-body "search served" --expect-trace-id 2>&1); [ $? -eq 1 ] && echo "$out" | grep -q "none carries a trace ID" && bash assert-logs.sh --logs-json "$tdir/untraced.json" --service search-api --expect-body "search served" >/dev/null'
check "an all-zero trace ID does not count" \
  '! bash assert-logs.sh --logs-json "$tdir/zero.json" --service search-api --expect-trace-id >/dev/null 2>&1'
rm -rf "$tdir"

echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
