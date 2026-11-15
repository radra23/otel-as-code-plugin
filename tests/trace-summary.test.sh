#!/usr/bin/env bash
# tests/trace-summary.test.sh: offline tests of scripts/trace_summary.py, /otel-why's evidence.
# The four recorded fixtures (tests/why/traces/<pattern>/) are real Tempo responses from the
# local stack, saved by tests/e2e/why.sh --record. The synthetic cases cover shapes a short run
# rarely produces. No network.
set -uo pipefail
cd "$(dirname "$0")/.."
pass=0; fail=0
check() { if eval "$2"; then echo "PASS: $1"; pass=$((pass+1)); else echo "FAIL: $1"; fail=$((fail+1)); fi; }
TS=scripts/trace_summary.py
T=tests/why/traces
TMPD=$(mktemp -d); trap 'rm -rf "$TMPD"' EXIT

# field <pattern> <python expression over s>: evaluate against that pattern's --json summary.
summary() { python3 "$TS" --trace-json "$T/$1"/*.json --route "POST /checkout" --json; }
field() { summary "$1" | python3 -c "import json,sys; s=json.load(sys.stdin); print($2)"; }

for p in n-plus-one slow-call cpu-bound clean; do
  check "$p: recorded fixture has traces" '[ "$(ls "$T/$p"/*.json 2>/dev/null | wc -l)" -ge 3 ]'
done

# N+1: the repeated lookup ranks first, stands out, and is detected as sequential siblings.
check "n-plus-one: db.getProduct ranks first and stands out" \
  '[ "$(field n-plus-one "s[\"rows\"][0][\"name\"], s[\"stands_out\"]")" = "db.getProduct True" ]'
check "n-plus-one: 30 calls per request" '[ "$(field n-plus-one "s[\"rows\"][0][\"per_request\"]")" = 30 ]'
check "n-plus-one: shape is one after another, under inventory.loadLines" \
  '[ "$(field n-plus-one "s[\"rows\"][0][\"shape\"][\"shape\"], s[\"rows\"][0][\"shape\"][\"under\"]")" = "one after another inventory.loadLines" ]'
check "n-plus-one: the text names the shape and calls it waiting" \
  'out=$(python3 "$TS" --trace-json "$T"/n-plus-one/*.json); echo "$out" | grep -q "^Shape: 30 calls one after another" && echo "$out" | grep -q "mostly waiting"'
check "n-plus-one: the parent's self time excludes its children" \
  '[ "$(field n-plus-one "[r for r in s[\"rows\"] if r[\"name\"]==\"inventory.loadLines\"][0][\"self_ms\"] < 20")" = True ]'

# Slow outbound call: the client span, grouped by where it went, and the "other side" caveat.
check "slow-call: the outbound GET ranks first and stands out" \
  '[ "$(field slow-call "s[\"rows\"][0][\"kind\"], s[\"rows\"][0][\"name\"], s[\"stands_out\"]")" = "client GET True" ]'
check "slow-call: the row names the target" \
  '[ "$(field slow-call "s[\"rows\"][0][\"span\"]")" = "GET http://127.0.0.1:4600/promotions" ]'
check "slow-call: the text says the trace can't see inside the other side" \
  'python3 "$TS" --trace-json "$T"/slow-call/*.json | grep -q "can.t see inside the other side"'

# CPU-bound: self time with no children, and the probe's CPU figure says computing.
check "cpu-bound: orders.signOrder ranks first, is a leaf, and stands out" \
  '[ "$(field cpu-bound "s[\"rows\"][0][\"name\"], s[\"rows\"][0][\"leaf\"], s[\"stands_out\"]")" = "orders.signOrder True True" ]'
check "cpu-bound: CPU close to elapsed, reported as computing" \
  'python3 "$TS" --trace-json "$T"/cpu-bound/*.json | grep -q "so this time is mostly computing"'
check "cpu-bound: it still says what a trace can't show and the next check" \
  'python3 "$TS" --trace-json "$T"/cpu-bound/*.json | grep -q "^A trace can.t show: .*Next check:"'

# Clean: something is always largest, but nothing stands out and no cause is named.
check "clean: nothing stands out and no top is named" \
  '[ "$(field clean "s[\"stands_out\"], s[\"top\"]")" = "False None" ]'
check "clean: the text says so instead of a cause" \
  'out=$(python3 "$TS" --trace-json "$T"/clean/*.json); echo "$out" | grep -q "^Nothing stands out" && ! echo "$out" | grep -q "^Stands out"'

# The table: probes are labelled as probes, the header says what was measured.
check "probe spans are labelled probe, auto-instrumentation auto" \
  '[ "$(field n-plus-one "sorted({r[\"source\"] for r in s[\"rows\"]}) == [\"auto\", \"probe\"]")" = True ]'
check "the rendered evidence starts with the trace count and request time" \
  'python3 "$TS" --trace-json "$T"/n-plus-one/*.json | head -1 | grep -q "^Evidence: 3 trace(s) of POST /checkout .*median"'

# --- synthetic traces ----------------------------------------------------------------------------
python3 - "$TMPD" <<'PY'
import json, os, sys
out = sys.argv[1]
MS = 1_000_000
def span(sid, parent, name, start, end, kind="SPAN_KIND_INTERNAL", attrs=None):
    return {"spanId": sid, "parentSpanId": parent, "name": name, "kind": kind,
            "startTimeUnixNano": str(start * MS), "endTimeUnixNano": str(end * MS),
            "attributes": [{"key": k, "value": v} for k, v in (attrs or {}).items()]}
def doc(spans, scope="app", base=0):
    for s in spans:
        s["startTimeUnixNano"] = str(int(s["startTimeUnixNano"]) + base * MS)
        s["endTimeUnixNano"] = str(int(s["endTimeUnixNano"]) + base * MS)
    return {"batches": [{"resource": {"attributes": [{"key": "service.name", "value": {"stringValue": "svc"}}]},
                         "scopeSpans": [{"scope": {"name": scope}, "spans": spans}]}]}
def save(name, d):
    json.dump(d, open(os.path.join(out, name + ".json"), "w"))
# 6 lookups at the same time, hex ids.
par = [span("aaaaaaaaaaaaaaaa", "", "GET /items", 0, 130, "SPAN_KIND_SERVER")]
par += [span(f"b{i:015x}", "aaaaaaaaaaaaaaaa", "db.get", 5, 125) for i in range(6)]
save("parallel", doc(par))
# Two outbound calls with the same span name to different services: two rows, not one.
two = [span("r1", "", "POST /pay", 0, 400, "SPAN_KIND_SERVER"),
       span("c1", "r1", "GET", 10, 300, "SPAN_KIND_CLIENT", {"url.full": {"stringValue": "http://fraud:80/check?id=1"}}),
       span("c2", "r1", "GET", 300, 390, "SPAN_KIND_CLIENT", {"server.address": {"stringValue": "ledger"}, "server.port": {"intValue": "443"}})]
save("two-targets", doc(two))
# Two requests that overlap in time, with a CPU-heavy probe: the CPU caveat must appear.
for n, base in (("overlap-1", 0), ("overlap-2", 100)):
    save(n, doc([span("r", "", "POST /x", 0, 400, "SPAN_KIND_SERVER"),
                 span("p", "r", "hash", 0, 390, attrs={"otel_as_code.probe.cpu_ms": {"doubleValue": 380.0}})],
                scope="otel-as-code.probe", base=base))
# A slow root with a health-check trace beside it, for the route filter.
save("health", doc([span("h", "", "GET /health", 0, 900, "SPAN_KIND_SERVER")]))
save("slow-root", doc([span("r", "", "POST /x", 0, 500, "SPAN_KIND_SERVER"), span("k", "r", "work", 0, 450)]))
PY
sjson() { python3 "$TS" --trace-json "$@" --json; }
check "parallel siblings are detected as at the same time (hex ids parsed)" \
  '[ "$(sjson "$TMPD/parallel.json" | python3 -c "import json,sys; r=[r for r in json.load(sys.stdin)[\"rows\"] if r[\"name\"]==\"db.get\"][0]; print(r[\"shape\"][\"shape\"], r[\"per_request\"])")" = "at the same time 6" ]'
check "parallel siblings: their self time is not summed past the request (union, not sum, for the parent)" \
  '[ "$(sjson "$TMPD/parallel.json" | python3 -c "import json,sys; r=[r for r in json.load(sys.stdin)[\"rows\"] if r[\"name\"]==\"GET /items\"][0]; print(r[\"self_ms\"])")" = "10.0" ]'
check "same-name outbound calls to two services stay two rows" \
  '[ "$(sjson "$TMPD/two-targets.json" | python3 -c "import json,sys; print(sorted(r[\"span\"] for r in json.load(sys.stdin)[\"rows\"] if r[\"kind\"]==\"client\") == [\"GET http://fraud:80/check\", \"GET ledger:443\"])")" = True ]'
check "overlapping requests are detected and the CPU figure is qualified" \
  'python3 "$TS" --trace-json "$TMPD"/overlap-*.json | grep -q "Requests overlapped in time, so the CPU figure may include other requests"'
check "--route keeps only traces whose root span has that name" \
  '[ "$(sjson "$TMPD/health.json" "$TMPD/slow-root.json" --route "POST /x" | python3 -c "import json,sys; s=json.load(sys.stdin); print(s[\"traces\"], s[\"root\"])")" = "1 POST /x" ]'
check "a span with no CPU figure and no children gets the elapsed-time-only caveat" \
  'python3 "$TS" --trace-json "$TMPD/slow-root.json" | grep -q "A trace measures elapsed time only"'
check "--min-ms raises the bar: a 450 ms span does not stand out at --min-ms 500" \
  '[ "$(sjson "$TMPD/slow-root.json" --min-ms 500 | python3 -c "import json,sys; print(json.load(sys.stdin)[\"stands_out\"])")" = False ]'

# --slowest: an intermittent symptom. 9 fast requests and 1 slow one with a lock wait: the median
# over all of them hides it; the slowest one shows it, and the header says the set was narrowed.
python3 - "$TMPD" <<'PY'
import json, os, sys
MS = 1_000_000
def span(sid, parent, name, start, end):
    return {"spanId": sid, "parentSpanId": parent, "name": name, "kind": "SPAN_KIND_INTERNAL",
            "startTimeUnixNano": str(start * MS), "endTimeUnixNano": str(end * MS), "attributes": []}
for i in range(10):
    base = i * 10_000
    slow = 2000 if i == 7 else 10
    spans = [span("r", "", "POST /login", base, base + slow + 5), span("q", "r", "session.lock", base, base + slow)]
    json.dump({"batches": [{"resource": {}, "scopeSpans": [{"scope": {"name": "app"}, "spans": spans}]}]},
              open(os.path.join(sys.argv[1], f"login-{i}.json"), "w"))
PY
check "an intermittent slow request: over all requests nothing stands out" \
  '[ "$(sjson "$TMPD"/login-*.json | python3 -c "import json,sys; print(json.load(sys.stdin)[\"stands_out\"])")" = False ]'
check "--slowest 1 shows the slow one standing out" \
  '[ "$(sjson "$TMPD"/login-*.json --slowest 1 | python3 -c "import json,sys; s=json.load(sys.stdin); print(s[\"stands_out\"], s[\"top\"], s[\"traces\"], s[\"traces_seen\"])")" = "True session.lock 1 10" ]'
check "--slowest says in the header that the set was narrowed" \
  'python3 "$TS" --trace-json "$TMPD"/login-*.json --slowest 1 | head -1 | grep -q "^Evidence: the 1 slowest of 10 trace(s)"'

# Exit codes: no matching trace is 1, unreadable input or an unreachable Grafana is 2.
python3 "$TS" --trace-json "$TMPD/health.json" --route "POST /none" >/dev/null 2>&1; rc=$?
check "no matching trace exits 1" '[ "$rc" -eq 1 ]'
python3 "$TS" --trace-json "$TMPD/missing.json" >/dev/null 2>&1; rc=$?
check "an unreadable file exits 2" '[ "$rc" -eq 2 ]'
free_port=$(python3 -c "import socket; s=socket.socket(); s.bind(('127.0.0.1',0)); print(s.getsockname()[1]); s.close()")
msg=$(python3 "$TS" --grafana "http://127.0.0.1:$free_port" --service svc 2>&1); rc=$?
check "an unreachable Grafana exits 2 and says unreachable" '[ "$rc" -eq 2 ] && echo "$msg" | grep -q "^unreachable:"'
check "the live query goes through Grafana's tempo proxy with explicit start and end" \
  'grep -q "api/datasources/proxy/uid/tempo/api" "$TS" && grep -q "\"start\": end - args.since, \"end\": end" "$TS"'
check "trace_summary.py talks to no host but the one it is given" \
  '! grep -nE "https?://[a-z0-9]" "$TS" | grep -v "localhost\|127.0.0.1" | grep -q .'

echo
echo "trace-summary: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
