#!/usr/bin/env bash
# tests/e2e/enrich.sh
# Proves /otel-enrich's spans end to end, for Node.js and Python, against the pinned
# grafana/otel-lgtm stack from the golden compose file:
#   - Node: tests/enrich/node-app + the golden tracing.js; spans around an async function, an
#     arrow function and a class method (scripts/enrich.py span).
#   - Python: fixtures/python-greenfield + the golden tracing.py; a span around a FastAPI route
#     handler, which must keep its signature (the request body still validates).
# Asserts, reading back the way /otel-enrich does (scripts/lgtm_check.py span, Tempo through
# Grafana's datasource proxy): each span arrives, nested where the code nests it; a thrown error
# is recorded on the span and still reaches the caller; and `enrich.py remove` restores every file
# byte for byte.
# Needs Docker with compose, Node 18+, Python 3.9+ with venv, and network for the image, npm and pip.
set -euo pipefail
cd "$(dirname "$0")/../.."
SRC=$PWD
WORK=$(mktemp -d)
APP_PID=""
stop() { [ -n "$APP_PID" ] && { kill "$APP_PID" 2>/dev/null || true; wait "$APP_PID" 2>/dev/null || true; }; APP_PID=""; }
cleanup() {
  stop
  (cd "$WORK/stack" && docker compose -f otel-local.compose.yaml down -v >/dev/null 2>&1) || true
  rm -rf "$WORK"
}
trap cleanup EXIT
enrich() { python3 "$SRC/scripts/enrich.py" "$@"; }
span() { python3 "$SRC/scripts/lgtm_check.py" span --grafana "http://localhost:$GRAFANA_PORT" --wait 90 "$@"; }
failed=0
ok() { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; failed=1; }

mkdir -p "$WORK/stack"
cp tests/snapshots/local-stack/otel-local.compose.yaml tests/snapshots/local-stack/otel-local.env "$WORK/stack/"
GRAFANA_PORT=$(sed -nE 's/.*"127\.0\.0\.1:([0-9]+):3000".*/\1/p' "$WORK/stack/otel-local.compose.yaml")
(cd "$WORK/stack" && docker compose -f otel-local.compose.yaml up -d)
for _ in $(seq 1 90); do curl -fsS "http://localhost:$GRAFANA_PORT/api/health" >/dev/null 2>&1 && break; sleep 2; done
curl -fsS "http://localhost:$GRAFANA_PORT/api/health" >/dev/null || { echo "FAIL: Grafana never answered"; exit 1; }
ok "local stack up, Grafana on :$GRAFANA_PORT"

# ---------------------------------------------------------------- Node.js
mkdir -p "$WORK/node"
cp -R tests/enrich/node-app/. "$WORK/node/"
cp tests/snapshots/instrument/nodejs/tracing.js "$WORK/node/tracing.js"
cd "$WORK/node"
npm install --no-audit --no-fund --loglevel=error
npm install --no-audit --no-fund --loglevel=error --save @opentelemetry/api    # the dependency note
cp -R "$WORK/node" "$WORK/node-before"
enrich span --root . --file lib/orders.js --function checkout --span-name orders.checkout --tracer-name enrich-orders >/dev/null
enrich span --root . --file lib/orders.js --function loadLines --span-name orders.loadLines --tracer-name enrich-orders >/dev/null
enrich span --root . --file lib/pricing.js --function Pricing.total --span-name pricing.total --tracer-name enrich-orders >/dev/null
(set -a; . "$WORK/stack/otel-local.env"; set +a; export OTEL_SERVICE_NAME=enrich-orders PORT=3900; exec node -r ./tracing.js index.js) \
  > app.log 2>&1 & APP_PID=$!
for _ in $(seq 1 30); do curl -fsS http://localhost:3900/health >/dev/null 2>&1 && break; sleep 1; done
body=$(curl -fsS -X POST -H 'Content-Type: application/json' -d '{"cartId":"c1"}' http://localhost:3900/checkout)
[ "$(printf '%s' "$body" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["status"], d["totalCents"])')" = "confirmed 900" ] \
  && ok "node: the enriched functions still return the same values" || { bad "node: response changed: $body"; cat app.log; }
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d '{"cartId":"c2","fail":true}' http://localhost:3900/checkout)
[ "$code" = 500 ] && ok "node: a thrown error still reaches the caller (HTTP 500)" || bad "node: expected 500 from the failing checkout, got $code"
stop
span --service enrich-orders --name orders.loadLines --parent orders.checkout \
  && ok "node: orders.loadLines arrived, nested under orders.checkout" || bad "node: orders.loadLines missing or not under orders.checkout"
out=$(span --service enrich-orders --name orders.checkout) && ! printf '%s' "$out" | grep -q "a root span" \
  && ok "node: orders.checkout arrived, inside the request's trace" || { bad "node: orders.checkout missing or a root span"; echo "$out"; }
span --service enrich-orders --name pricing.total >/dev/null \
  && ok "node: pricing.total (a class method) arrived" || bad "node: pricing.total missing"
span --service enrich-orders --name orders.checkout --status error >/dev/null \
  && ok "node: the failing checkout's span recorded the error" || bad "node: no orders.checkout span with an error"
enrich remove --root . >/dev/null
rm -f app.log
diff -r "$WORK/node-before" "$WORK/node" >/dev/null \
  && ok "node: enrich.py remove restored every file byte for byte" || { bad "node: files differ after removal"; diff -r "$WORK/node-before" "$WORK/node" | head; }

# ---------------------------------------------------------------- Python
mkdir -p "$WORK/py"
cp -R "$SRC/fixtures/python-greenfield/." "$WORK/py/"
cp "$SRC/tests/snapshots/instrument/python/tracing.py" "$SRC/tests/snapshots/instrument/python/requirements.txt" "$WORK/py/"
cd "$WORK/py"
printf 'import tracing\nfrom app import app\ntracing.instrument_fastapi(app)\n' > main.py
python3 -m venv "$WORK/venv"
"$WORK/venv/bin/pip" install -q --disable-pip-version-check -r requirements.txt
cp app.py "$WORK/app.before.py"
enrich span --root . --file app.py --function reserve_stock --span-name inventory.reserve_stock --tracer-name inventory-api >/dev/null
(set -a; . "$WORK/stack/otel-local.env"; set +a; export OTEL_SERVICE_NAME=enrich-inventory; exec "$WORK/venv/bin/uvicorn" main:app --port 8900) \
  > app.log 2>&1 & APP_PID=$!
for _ in $(seq 1 30); do curl -fsS http://localhost:8900/health >/dev/null 2>&1 && break; sleep 1; done
body=$(curl -fsS -X POST -H 'Content-Type: application/json' -d '{"sku":"s1","quantity":2,"warehouse":"w"}' http://localhost:8900/inventory/reserve)
[ "$(printf '%s' "$body" | python3 -c 'import json,sys; print(json.load(sys.stdin)["reserved"])')" = True ] \
  && ok "python: the enriched route handler still answers" || { bad "python: response changed: $body"; cat app.log; }
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d '{"sku":"s1"}' http://localhost:8900/inventory/reserve)
[ "$code" = 422 ] && ok "python: the handler kept its signature (a bad body is still rejected with 422)" || bad "python: expected 422 for a bad body, got $code"
stop    # the bootstrap flushes on SIGTERM (#295), so the span is read back after the stop
out=$(span --service enrich-inventory --name inventory.reserve_stock) && ! printf '%s' "$out" | grep -q "a root span" \
  && ok "python: inventory.reserve_stock arrived, inside the request's trace" || { bad "python: inventory.reserve_stock missing or a root span"; echo "$out"; cat app.log; }
enrich remove --root . >/dev/null
cmp -s app.py "$WORK/app.before.py" \
  && ok "python: enrich.py remove restored app.py byte for byte" || bad "python: app.py differs after removal"

[ "$failed" -eq 0 ] && echo "ENRICH E2E PASS: every added span reached the local stack, and removal restored the code"
exit "$failed"
