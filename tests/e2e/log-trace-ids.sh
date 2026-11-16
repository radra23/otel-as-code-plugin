#!/usr/bin/env bash
# tests/e2e/log-trace-ids.sh
# Trace IDs in log lines (#279): a line logged while a request is handled carries the trace ID
# of that request's span, and the application's own logging setup is left as it was.
#   - Python: fixtures/python-greenfield (FastAPI + the standard `logging` module) behind the
#     golden tracing.py, with five logging setups an app might have (tests/log-trace-ids/main.py).
#     The plain formatter gets the IDs appended after the app's own format; a JSON formatter gets
#     them as fields; a custom formatter class, hand-made JSON and a format that already shows the
#     ID are not touched. The --experimental golden is run once to prove it carries the same block.
#   - Node.js: express + pino, winston and bunyan behind the golden tracing.js. The bundle's
#     instrumentations already add the IDs; this pins it. console.log gets nothing, which is said
#     in the docs and held here so it stays true.
# The span's trace ID is read from the console exporter, the log line from the app's output, and
# the two must be equal: a trace ID that is merely present would not prove the link. No Docker.
# Needs Node 18+, Python 3.9+ with venv, and network for npm and pip.
set -euo pipefail
cd "$(dirname "$0")/../.."
SRC=$PWD
WORK=$(mktemp -d)
APP_PID=""
stop() { [ -n "$APP_PID" ] && { kill "$APP_PID" 2>/dev/null || true; wait "$APP_PID" 2>/dev/null || true; }; APP_PID=""; }
trap 'stop; rm -rf "$WORK"' EXIT
failed=0
ok() { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; failed=1; }
wait_up() { for _ in $(seq 1 60); do curl -fsS "$1" >/dev/null 2>&1 && return 0; sleep 0.5; done; return 1; }

# ---------------------------------------------------------------- Python
mkdir -p "$WORK/py"
cp "$SRC/fixtures/python-greenfield/app.py" "$SRC/tests/log-trace-ids/main.py" \
   "$SRC/tests/snapshots/instrument/python/requirements.txt" "$WORK/py/"
cd "$WORK/py"
python3 -m venv "$WORK/venv"
"$WORK/venv/bin/pip" install -q --disable-pip-version-check -r requirements.txt python-json-logger

# py_request <mode> [VAR=value ...]: run the service with that logging setup, reserve stock once,
# stop it. Spans land in <mode>.spans (stdout), log lines in <mode>.logs (stderr).
py_request() {
  local mode="$1"; shift
  env LOG_MODE="$mode" OTEL_TRACES_EXPORTER=console OTEL_METRICS_EXPORTER=none "$@" \
    "$WORK/venv/bin/uvicorn" main:app --port 8930 --no-access-log > "$mode.spans" 2> "$mode.logs" & APP_PID=$!
  wait_up http://localhost:8930/health || { bad "python ($mode): the service did not start"; cat "$mode.logs"; }
  curl -fsS -o /dev/null -X POST -H 'Content-Type: application/json' \
    -d '{"sku":"A-1","quantity":2,"warehouse":"us-east-1"}' http://localhost:8930/inventory/reserve
  stop
}
# The trace ID of the request's server span, from the console exporter's JSON.
py_trace_id() {
  python3 - "$1" <<'PY'
import json, re, sys
text = open(sys.argv[1], encoding="utf-8").read()
decoder = json.JSONDecoder()
ids = set()
for m in re.finditer(r"(?m)^\{$", text):
    try:
        span, _ = decoder.raw_decode(text, m.start())
    except json.JSONDecodeError:
        continue
    if span.get("kind") == "SpanKind.SERVER" and "/inventory/reserve" in span.get("name", ""):
        ids.add(span["context"]["trace_id"].removeprefix("0x"))
print(ids.pop() if len(ids) == 1 else f"expected one server span, found {len(ids)}")
PY
}
line_of() { grep -F "reserved sku=A-1" "$1" | head -1; }

cp "$SRC/tests/snapshots/instrument/python/tracing.py" tracing.py

py_request plain
tid=$(py_trace_id plain.spans); line=$(line_of plain.logs)
[[ "$tid" =~ ^[0-9a-f]{32}$ ]] && ok "python: the request made one server span" || { bad "python: $tid"; tail -20 plain.spans; }
[[ "$line" == "APP INFO inventory | reserved sku=A-1 qty=2 warehouse=us-east-1 trace_id=$tid span_id="* ]] \
  && ok "python (plain): the app's own format is kept and the line ends with the request's trace ID" \
  || { bad "python (plain): unexpected line"; echo "  line:  $line"; echo "  trace: $tid"; }
[[ "$line" =~ span_id=[0-9a-f]{16}$ ]] && ok "python (plain): the span ID follows, 16 hex digits" || bad "python (plain): no span ID at the end: $line"
grep -F "Application startup complete" plain.logs | grep -q "trace_id=" \
  && bad "python (plain): a line logged outside any request got a trace ID" \
  || ok "python (plain): a line logged outside a request is left as it was"

py_request json
tid=$(py_trace_id json.spans); line=$(line_of json.logs)
got=$(printf '%s' "$line" | python3 -c 'import json,sys; r=json.loads(sys.stdin.read()); print(r.get("otelTraceID"), len(r.get("otelSpanID","")))' 2>&1)
[ "$got" = "$tid 16" ] && ok "python (json): the line is still valid JSON and carries the trace ID as a field" \
  || { bad "python (json): got '$got', expected '$tid 16'"; echo "  $line"; }

py_request custom
tid=$(py_trace_id custom.spans); line=$(line_of custom.logs)
[ "$line" = '{"line": "INFO reserved sku=A-1 qty=2 warehouse=us-east-1"}' ] \
  && ok "python (custom formatter class): the line is exactly what the app's formatter wrote" \
  || { bad "python (custom): the line was changed"; echo "  $line"; }

py_request handmade-json
line=$(line_of handmade-json.logs)
[ "$line" = '{"level": "INFO", "msg": "reserved sku=A-1 qty=2 warehouse=us-east-1"}' ] \
  && ok "python (JSON from a format string): nothing is appended after the closing brace" \
  || { bad "python (handmade-json): the line was changed"; echo "  $line"; }

py_request own-ids
tid=$(py_trace_id own-ids.spans); line=$(line_of own-ids.logs)
[ "$line" = "INFO [$tid] reserved sku=A-1 qty=2 warehouse=us-east-1" ] \
  && ok "python (format already shows the ID): the field is filled in and nothing is added twice" \
  || { bad "python (own-ids): unexpected line"; echo "  $line"; echo "  trace: $tid"; }

py_request plain OTEL_AS_CODE_LOG_TRACE_IDS=off
line=$(line_of plain.logs)
[ "$line" = "APP INFO inventory | reserved sku=A-1 qty=2 warehouse=us-east-1" ] \
  && ok "python: OTEL_AS_CODE_LOG_TRACE_IDS=off leaves the line alone" || { bad "python (off): $line"; }

py_request plain OTEL_TRACES_EXPORTER=none
line=$(line_of plain.logs)
[ "$line" = "APP INFO inventory | reserved sku=A-1 qty=2 warehouse=us-east-1" ] \
  && ok "python: with traces off there is no span, so nothing is appended" || { bad "python (traces off): $line"; }

cp "$SRC/tests/snapshots/instrument/python/tracing.experimental.py" tracing.py
py_request plain OTEL_LOGS_EXPORTER=none
tid=$(py_trace_id plain.spans); line=$(line_of plain.logs)
[[ "$tid" =~ ^[0-9a-f]{32}$ && "$line" == *" trace_id=$tid span_id="* ]] \
  && ok "python (--experimental bootstrap): the same line carries the request's trace ID" \
  || { bad "python (--experimental): unexpected line"; echo "  line:  $line"; echo "  trace: $tid"; }

# ---------------------------------------------------------------- Node.js
mkdir -p "$WORK/node"
cp "$SRC/tests/log-trace-ids/node-app.js" "$WORK/node/app.js"
cp "$SRC/tests/snapshots/instrument/nodejs/tracing.js" "$SRC/tests/snapshots/instrument/nodejs/package.json" "$WORK/node/"
cd "$WORK/node"
npm install --no-audit --no-fund --silent
npm install --no-audit --no-fund --silent --no-save express pino winston bunyan
node_request() {   # node_request <out> [VAR=value ...]
  local out="$1"; shift
  env PORT=3920 OTEL_TRACES_EXPORTER=console OTEL_METRICS_EXPORTER=none "$@" node --require ./tracing.js app.js > "$out" 2>&1 & APP_PID=$!
  wait_up http://localhost:3920/health || { bad "node: the service did not start"; cat "$out"; }
  curl -fsS -o /dev/null http://localhost:3920/orders/7
  sleep 1; stop
}
# field <out> <text in the line> <json field>
field() { grep -F "$2" "$1" | head -1 | python3 -c 'import json,sys; print(json.loads(sys.stdin.read()).get(sys.argv[1], "absent"))' "$3" 2>/dev/null || echo "not-json"; }

node_request on.log
# The console exporter prints each span as a JavaScript object; the /orders request's server span
# is the one whose http.route is /orders/:id.
ntid=$(python3 - on.log <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
ids = {m.group(1) for block in re.split(r"(?m)^\{$", text) if "/orders/:id" in block
       for m in [re.search(r"traceId: '([0-9a-f]{32})'", block)] if m}
print(ids.pop() if len(ids) == 1 else f"expected one trace for /orders/:id, found {len(ids)}")
PY
)
[[ "$ntid" =~ ^[0-9a-f]{32}$ ]] && ok "node: the request made one trace" || { bad "node: $ntid"; tail -40 on.log; }
for lib in pino winston bunyan; do
  [ "$(field on.log "$lib order line" trace_id)" = "$ntid" ] \
    && ok "node ($lib): the line carries the request's trace ID" \
    || { bad "node ($lib): trace_id is '$(field on.log "$lib order line" trace_id)', expected '$ntid'"; grep -F "$lib order line" on.log; }
  [[ "$(field on.log "$lib order line" span_id)" =~ ^[0-9a-f]{16}$ ]] \
    && ok "node ($lib): and a span ID" || bad "node ($lib): no span_id"
done
[ "$(grep -Fx 'console order line' on.log | wc -l | tr -d ' ')" = 1 ] \
  && ok "node: console.log is not covered and its line is untouched (documented)" \
  || { bad "node: the console.log line changed"; grep -F 'console order line' on.log; }

node_request off.log OTEL_TRACES_EXPORTER=none
[ "$(field off.log "pino order line" trace_id)" = absent ] \
  && ok "node: with traces off the lines carry no trace ID (documented)" \
  || bad "node: a trace ID appeared with traces off: $(grep -F 'pino order line' off.log)"

[ "$failed" -eq 0 ] && echo "LOG TRACE IDS E2E PASS: log lines carry their request's trace ID, and the app's logging setup is untouched" \
  || { echo "LOG TRACE IDS E2E FAIL"; exit 1; }
