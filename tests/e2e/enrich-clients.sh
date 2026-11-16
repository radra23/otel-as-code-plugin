#!/usr/bin/env bash
# tests/e2e/enrich-clients.sh
# Proves /otel-enrich --clients against real packages, with the rule it exists for: exactly one
# client span per database call.
#   - Python: tests/enrich/py-clients (FastAPI + the standard library's sqlite3) with the golden
#     tracing.py. Before: no client span at all. After `enrich.py client --name sqlite3` and a
#     plain `pip install -r requirements.txt`: one per query.
#   - Node.js: tests/enrich/node-clients (express + node:sqlite, which no package covers) with the
#     golden tracing.js. `enrich.py span --client node:sqlite` around the function that queries:
#     one client span per call. `pg`, which the bundle covers, is refused a hand-made span.
# Spans are read from the console exporter (OTEL_TRACES_EXPORTER=console), where every span the
# process made is visible, so "exactly one" is a count and not a search. No Docker.
# Needs Node 22.13+ (node:sqlite), Python 3.9+ with venv, and network for npm and pip.
set -euo pipefail
cd "$(dirname "$0")/../.."
SRC=$PWD
WORK=$(mktemp -d)
APP_PID=""
stop() { [ -n "$APP_PID" ] && { kill "$APP_PID" 2>/dev/null || true; wait "$APP_PID" 2>/dev/null || true; }; APP_PID=""; }
trap 'stop; rm -rf "$WORK"' EXIT
enrich() { python3 "$SRC/scripts/enrich.py" "$@"; }
failed=0
ok() { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; failed=1; }
# is <name> <actual> <expected>
is() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', expected '$3')"; fi; }
status_of() { enrich clients --root . --json "${@:2}" | python3 -c '
import json, sys
rows = {r["client"]: r["status"] for r in json.load(sys.stdin)["clients"]}
print(rows.get(sys.argv[1], "absent"))' "$1"; }
wait_up() { for _ in $(seq 1 40); do curl -fsS "$1" >/dev/null 2>&1 && return 0; sleep 0.5; done; return 1; }
get() { curl -s -o /dev/null -w '%{http_code}' "$1"; }

# ---------------------------------------------------------------- Python
mkdir -p "$WORK/py"
cp "$SRC/tests/enrich/py-clients/app.py" "$SRC/tests/snapshots/instrument/python/tracing.py" \
   "$SRC/tests/snapshots/instrument/python/requirements.txt" "$WORK/py/"
cd "$WORK/py"
printf 'import tracing\nfrom app import app\ntracing.instrument_fastapi(app)\n' > main.py
cp -R "$WORK/py" "$WORK/py-before"
python3 -m venv "$WORK/venv"
"$WORK/venv/bin/pip" install -q --disable-pip-version-check -r requirements.txt
py_run() {   # py_run <log>: start the service printing its spans to <log>
  OTEL_TRACES_EXPORTER=console OTEL_METRICS_EXPORTER=none OTEL_SERVICE_NAME=enrich-catalog \
    "$WORK/venv/bin/uvicorn" main:app --port 8910 > "$1" 2>&1 & APP_PID=$!
  wait_up http://localhost:8910/health || { bad "python: the service did not start"; cat "$1"; }
}
py_clients() { grep -c '"kind": "SpanKind.CLIENT"' "$1" || true; }

is "python: sqlite3 is reported as a client whose package is not installed" "$(status_of sqlite3)" install
py_run "$WORK/before.log"; get http://localhost:8910/items/1 >/dev/null; stop
is "python: before, a query makes no client span (the gap this closes)" "$(py_clients "$WORK/before.log")" 0

enrich client --root . --name sqlite3 --bootstrap tracing.py >/dev/null
grep -q '^opentelemetry-instrumentation-sqlite3>=0.66b2$' requirements.txt \
  && ok "python: the requirement is pinned to the release the other instrumentation package uses" \
  || { bad "python: requirement line missing or unpinned"; tail -4 requirements.txt; }
"$WORK/venv/bin/pip" install -q --disable-pip-version-check -r requirements.txt
is "python: after the install, sqlite3 is reported as turned on" "$(status_of sqlite3)" enabled
out=$(enrich client --root . --name sqlite3 --bootstrap tracing.py 2>&1) && rc=0 || rc=$?
{ [ "$rc" = 2 ] && printf '%s' "$out" | grep -q "Nothing to add"; } \
  && ok "python: turning it on twice is refused" || bad "python: a second run was not refused: $out"

py_run "$WORK/after.log"
codes="$(get http://localhost:8910/items/1) $(get http://localhost:8910/items/2) $(get http://localhost:8910/items/1) $(get http://localhost:8910/items/9)"
stop
is "python: the service answers as before (three hits, one 404)" "$codes" "200 200 200 404"
is "python: four queries made exactly four client spans, one each" "$(py_clients "$WORK/after.log")" 4
grep -q '"name": "SELECT"' "$WORK/after.log" \
  && ok "python: the client spans come from the package (named after the statement)" \
  || { bad "python: no SELECT span in the output"; tail -40 "$WORK/after.log"; }
! grep -q "is not installed" "$WORK/after.log" \
  && ok "python: the bootstrap found the package" || bad "python: the bootstrap reported the package missing"

enrich remove --root . >/dev/null
rm -rf __pycache__ "$WORK/py-before/__pycache__"
diff -r "$WORK/py-before" "$WORK/py" >/dev/null \
  && ok "python: enrich.py remove restored the bootstrap and requirements.txt byte for byte" \
  || { bad "python: files differ after removal"; diff -r "$WORK/py-before" "$WORK/py" | head; }

# ---------------------------------------------------------------- Node.js
mkdir -p "$WORK/node"
cp -R "$SRC/tests/enrich/node-clients/." "$WORK/node/"
cp "$SRC/tests/snapshots/instrument/nodejs/tracing.js" "$WORK/node/tracing.js"
cd "$WORK/node"
is "node: before the install, pg's coverage is reported as not checked" "$(status_of pg --bootstrap tracing.js)" not-checked
npm install --no-audit --no-fund --loglevel=error
cp -R "$WORK/node" "$WORK/node-before"
is "node: pg is covered by the bundle the bootstrap loads" "$(status_of pg --bootstrap tracing.js)" covered
is "node: node:sqlite has no package and is offered a client span" "$(status_of node:sqlite --bootstrap tracing.js)" wrap
SPAN=(--root . --file lib/store.js --function findItem --span-name store.findItem --tracer-name enrich-catalog)
out=$(enrich span "${SPAN[@]}" --client pg 2>&1) && rc=0 || rc=$?
{ [ "$rc" = 2 ] && printf '%s' "$out" | grep -q "two client spans per call"; } \
  && ok "node: a hand-made span for a client the bundle covers is refused" || bad "node: --client pg was not refused: $out"
enrich span "${SPAN[@]}" --client node:sqlite >/dev/null
OTEL_TRACES_EXPORTER=console OTEL_METRICS_EXPORTER=none OTEL_SERVICE_NAME=enrich-catalog PORT=3910 \
  node -r ./tracing.js index.js > "$WORK/node.log" 2>&1 & APP_PID=$!
wait_up http://localhost:3910/health || { bad "node: the service did not start"; cat "$WORK/node.log"; }
codes="$(get http://localhost:3910/items/1) $(get http://localhost:3910/items/2) $(get http://localhost:3910/items/9)"
stop
is "node: the service answers as before (two hits, one 404)" "$codes" "200 200 404"
is "node: three calls made exactly three client spans, one each" "$(grep -c '^ *kind: 2,' "$WORK/node.log" || true)" 3
is "node: each one is the span around findItem, marked as a SQLite call" \
  "$(grep -c "name: 'store.findItem'" "$WORK/node.log" || true) $(grep -c "'db.system.name': 'sqlite'" "$WORK/node.log" || true)" "3 3"
enrich remove --root . >/dev/null
diff -r "$WORK/node-before" "$WORK/node" >/dev/null \
  && ok "node: enrich.py remove restored every file byte for byte" || { bad "node: files differ after removal"; diff -r "$WORK/node-before" "$WORK/node" | head; }

[ "$failed" -eq 0 ] && echo "ENRICH CLIENTS E2E PASS: one client span per call, and removal restored the code"
exit "$failed"
