#!/usr/bin/env bash
# tests/e2e/local-stack.sh
# Proves /otel-local end to end with the committed goldens: the pinned grafana/otel-lgtm stack
# from tests/snapshots/local-stack/otel-local.compose.yaml, and fixtures/nodejs-greenfield (which
# listens on 3000, so Grafana is on host 3001) with the golden tracing.js loaded from the golden
# otel-local.env. Asserts:
#   1. without otel-local.env loaded the app exports nothing (the deployed default is unchanged);
#   2. with it loaded, a trace for checkout-api arrives, read back the way /otel-local reads it:
#      Tempo through Grafana's datasource proxy with explicit start/end (assert-lgtm.sh, which
#      runs scripts/lgtm_check.py).
# Needs Docker with compose, Node 18+, and network access for the image and npm.
set -euo pipefail
cd "$(dirname "$0")/../.."
SRC=$PWD
WORK=$(mktemp -d)
APP_PID=""
cleanup() {
  [ -n "$APP_PID" ] && kill "$APP_PID" 2>/dev/null || true
  (cd "$WORK" && docker compose -f otel-local.compose.yaml down -v >/dev/null 2>&1) || true
  rm -rf "$WORK"
}
trap cleanup EXIT

cp -R fixtures/nodejs-greenfield/. "$WORK/"
cp tests/snapshots/instrument/nodejs/tracing.js "$WORK/tracing.js"
cp tests/snapshots/instrument/nodejs/package.json "$WORK/package.json"      # instrumented manifest
cp tests/snapshots/local-stack/otel-local.compose.yaml "$WORK/otel-local.compose.yaml"
cp tests/snapshots/local-stack/otel-local.env "$WORK/otel-local.env"
cd "$WORK"

GRAFANA_PORT=$(sed -nE 's/.*"127\.0\.0\.1:([0-9]+):3000".*/\1/p' otel-local.compose.yaml)
[ "$GRAFANA_PORT" = "3001" ] || { echo "FAIL: golden compose should map Grafana to host 3001 (app is on 3000), got '$GRAFANA_PORT'"; exit 1; }

docker compose -f otel-local.compose.yaml config -q
echo "PASS: golden compose file is valid"

python3 "$SRC/scripts/lgtm_check.py" ports --grafana-port "$GRAFANA_PORT"
docker compose -f otel-local.compose.yaml up -d

for _ in $(seq 1 90); do
  curl -fsS "http://localhost:$GRAFANA_PORT/api/health" >/dev/null 2>&1 && break
  sleep 2
done
curl -fsS "http://localhost:$GRAFANA_PORT/api/health" >/dev/null || {
  echo "FAIL: Grafana never answered on :$GRAFANA_PORT"
  docker compose -f otel-local.compose.yaml logs --tail 50 lgtm
  exit 1
}
echo "PASS: Grafana up on host :$GRAFANA_PORT"

npm install --no-audit --no-fund --loglevel=error

wait_app() {
  for _ in $(seq 1 30); do curl -fsS http://localhost:3000/health >/dev/null 2>&1 && return 0; sleep 1; done
  echo "FAIL: app never answered on :3000"; cat app.log; return 1
}

# 1. Deployed default: no env file, no endpoint -> every exporter is `none`, and it says so.
node -r ./tracing.js index.js > app.log 2>&1 & APP_PID=$!
wait_app
grep -q "this process emits no telemetry" app.log \
  || { echo "FAIL: without otel-local.env the bootstrap should export nothing and say so"; cat app.log; exit 1; }
kill "$APP_PID"; wait "$APP_PID" 2>/dev/null || true; APP_PID=""
echo "PASS: without otel-local.env the app exports nothing (deployed default unchanged)"

# 2. Local wiring: the exact load line the env file documents.
(set -a; . ./otel-local.env; set +a; exec node -r ./tracing.js index.js) > app.log 2>&1 & APP_PID=$!
wait_app
for i in 1 2 3 4 5; do
  curl -fsS -X POST -H 'Content-Type: application/json' -d "{\"cartId\":\"c$i\",\"userId\":\"u$i\"}" \
    http://localhost:3000/checkout >/dev/null
done

bash "$SRC/tests/e2e/assert-lgtm.sh" --grafana "http://localhost:$GRAFANA_PORT" --service checkout-api --wait 90
echo "LOCAL STACK E2E PASS: a checkout-api trace reached grafana/otel-lgtm and was read back through Grafana's datasource proxy"
