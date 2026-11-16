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
#
# Business metrics (scripts/enrich.py metric, names from tests/enrich/context.json): the Node app
# emits the counter and the histogram the Grafana golden has panels for, and the panels' OWN
# queries, read out of tests/snapshots/grafana/main.tf.snap, must return data from the stack's
# Prometheus. The Python app does the same against the documented query shapes.
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
CTX="$SRC/tests/enrich/context.json"
metric() { python3 "$SRC/scripts/enrich.py" metric --context "$CTX" "$@"; }
ln_of() { grep -n -F -- "$2" "$1" | head -1 | cut -d: -f1; }
# panel_ok <name> <promql> <names regex> [--positive]: the query returns a number; on failure show
# what Prometheus has under similar names, and with which job labels.
panel_ok() {
  local name="$1" expr="$2" names="$3"; shift 3
  if python3 "$SRC/scripts/lgtm_check.py" query --grafana "http://localhost:$GRAFANA_PORT" --expr "$expr" --wait 120 --names "$names" "$@"; then
    ok "$name"
  else
    bad "$name"
    curl -s -G "http://localhost:$GRAFANA_PORT/api/datasources/proxy/uid/prometheus/api/v1/query" \
      --data-urlencode "query=count by (__name__, job) ({__name__=~\"$names\"})" | head -c 1500; echo
  fi
}
# golden_expr <text the expr contains> <job>: one panel query from the Grafana golden, ready to run.
golden_expr() {
  python3 - "$SRC/tests/snapshots/grafana/main.tf.snap" "$1" "$2" <<'PY'
import re, sys
snap, needle, job = sys.argv[1:4]
for line in open(snap, encoding="utf-8"):
    m = re.match(r'\s*expr\s*=\s*"(.*)"\s*$', line)
    if m and needle in m.group(1):
        print(m.group(1).replace('\\"', '"').replace("${var.service_name}", job))
        break
else:
    sys.exit(f"no panel query containing {needle!r} in {snap}")
PY
}
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
RET="return { cartId, lines, status: 'confirmed' };"
metric --root . --file lib/orders.js --function checkout --at "$(ln_of lib/orders.js "$RET")" --where before \
  --name com.example.checkout.order_placed --meter-name enrich-orders >/dev/null
metric --root . --file lib/orders.js --function checkout --at "$(ln_of lib/orders.js "$RET")" --where before \
  --name com.example.checkout.payment_duration --value "(Date.now() - startedAt) / 1000" --meter-name enrich-orders >/dev/null
(set -a; . "$WORK/stack/otel-local.env"; set +a; export OTEL_SERVICE_NAME=enrich-orders PORT=3900; exec node -r ./tracing.js index.js) \
  > app.log 2>&1 & APP_PID=$!
for _ in $(seq 1 30); do curl -fsS http://localhost:3900/health >/dev/null 2>&1 && break; sleep 1; done
body=$(curl -fsS -X POST -H 'Content-Type: application/json' -d '{"cartId":"c1"}' http://localhost:3900/checkout)
[ "$(printf '%s' "$body" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["status"], d["totalCents"])')" = "confirmed 900" ] \
  && ok "node: the enriched functions still return the same values" || { bad "node: response changed: $body"; cat app.log; }
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d '{"cartId":"c2","fail":true}' http://localhost:3900/checkout)
[ "$code" = 500 ] && ok "node: a thrown error still reaches the caller (HTTP 500)" || bad "node: expected 500 from the failing checkout, got $code"
# Business metrics, while the app is still exporting (every 5 s with otel-local.env): five more
# successful checkouts in two bursts, so a rate() over the stored samples has something to show.
checkout_ok() { curl -fsS -o /dev/null -X POST -H 'Content-Type: application/json' -d '{"cartId":"c1"}' http://localhost:3900/checkout; }
checkout_ok; checkout_ok; sleep 7; checkout_ok; checkout_ok; checkout_ok
NODE_JOB="storefront/enrich-orders"     # Prometheus's job label is <service.namespace>/<service.name>
panel_ok "node: the golden counter panel's query returns data" \
  "$(golden_expr com_example_checkout_order_placed_total "$NODE_JOB")" "com_example_checkout.*" --positive
# The checkouts take about 5 ms. With the SDK's default buckets every quantile under 5 s reads
# 2.5; the boundaries enrich.py sets for a histogram in seconds must give a real figure.
panel_ok "node: the golden histogram panel's p50 query returns a duration well under a second" \
  "$(golden_expr 'histogram_quantile(0.50, sum(rate(com_example_checkout_payment_duration' "$NODE_JOB")" "com_example_checkout.*" --positive --max 0.1
out=$(python3 "$SRC/scripts/lgtm_check.py" query --grafana "http://localhost:$GRAFANA_PORT" --wait 30 \
        --expr "sum(com_example_checkout_order_placed_total{job=\"$NODE_JOB\"})")
printf '%s' "$out" | grep -q "first value 6$" \
  && ok "node: the counter counted the 6 successful checkouts and not the failing one" || { bad "node: expected the counter at 6"; echo "$out"; }
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
PRET='return {"reserved": True'
metric --root . --file app.py --function reserve_stock --at "$(ln_of app.py "$PRET")" --where before \
  --name com.example.inventory.reservations --meter-name inventory-api >/dev/null
metric --root . --file app.py --function reserve_stock --at "$(ln_of app.py "$PRET")" --where before \
  --name com.example.inventory.reserved_quantity --value "update.quantity" --meter-name inventory-api >/dev/null
(set -a; . "$WORK/stack/otel-local.env"; set +a; export OTEL_SERVICE_NAME=enrich-inventory; exec "$WORK/venv/bin/uvicorn" main:app --port 8900) \
  > app.log 2>&1 & APP_PID=$!
for _ in $(seq 1 30); do curl -fsS http://localhost:8900/health >/dev/null 2>&1 && break; sleep 1; done
body=$(curl -fsS -X POST -H 'Content-Type: application/json' -d '{"sku":"s1","quantity":2,"warehouse":"w"}' http://localhost:8900/inventory/reserve)
[ "$(printf '%s' "$body" | python3 -c 'import json,sys; print(json.load(sys.stdin)["reserved"])')" = True ] \
  && ok "python: the enriched route handler still answers" || { bad "python: response changed: $body"; cat app.log; }
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d '{"sku":"s1"}' http://localhost:8900/inventory/reserve)
[ "$code" = 422 ] && ok "python: the handler kept its signature (a bad body is still rejected with 422)" || bad "python: expected 422 for a bad body, got $code"
# Business metrics while the app is still up. The Python bootstrap exports metrics every 30 s, so
# the second burst waits for one export to have gone out.
reserve_ok() { curl -fsS -o /dev/null -X POST -H 'Content-Type: application/json' -d '{"sku":"s1","quantity":2,"warehouse":"w"}' http://localhost:8900/inventory/reserve; }
sleep 32; reserve_ok; reserve_ok
PY_JOB="storefront/enrich-inventory"
panel_ok "python: the counter panel query (the documented shape) returns data" \
  "sum(rate(com_example_inventory_reservations_total{job=\"$PY_JOB\"}[5m]))" "com_example_inventory.*" --positive
panel_ok "python: the histogram panel query (no unit suffix for a {item} unit) returns data" \
  "histogram_quantile(0.50, sum(rate(com_example_inventory_reserved_quantity_bucket{job=\"$PY_JOB\"}[5m])) by (le))" "com_example_inventory.*"
stop    # the bootstrap flushes on SIGTERM (#295), so the span is read back after the stop
out=$(span --service enrich-inventory --name inventory.reserve_stock) && ! printf '%s' "$out" | grep -q "a root span" \
  && ok "python: inventory.reserve_stock arrived, inside the request's trace" || { bad "python: inventory.reserve_stock missing or a root span"; echo "$out"; cat app.log; }
enrich remove --root . >/dev/null
cmp -s app.py "$WORK/app.before.py" \
  && ok "python: enrich.py remove restored app.py byte for byte" || bad "python: app.py differs after removal"

[ "$failed" -eq 0 ] && echo "ENRICH E2E PASS: every added span reached the local stack, and removal restored the code"
exit "$failed"
