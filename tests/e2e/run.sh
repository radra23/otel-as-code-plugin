#!/usr/bin/env bash
# tests/e2e/run.sh — bring up the stack, drive load, assert traces for both services, tear down.
#
# #1 integration: seeds throwaway copies of the greenfield fixtures + golden bootstraps
# under ./.work (fixtures/ stays pristine), brings up jaeger + collector + node-app +
# python-app via docker-compose.yml, drives load against BOTH apps from the host
# (node-app:3000 and python-app:8000 are published to the host — see docker-compose.yml),
# then asserts real traces landed in Jaeger with the correct service.* resource attrs.
# Always tears down and cleans up, even on failure.
set -euo pipefail
cd "$(dirname "$0")"

WORK="./.work"
cleanup() {
  # NOTE: this dump will include expected/harmless OTLP export-retry errors for the
  # metrics/logs pipelines (Jaeger's OTLP receiver only accepts traces) — see the
  # "Expected collector errors" section in README.md before treating those as the failure.
  echo "--- collector + app logs (tail, timestamped) ---"
  docker compose logs --timestamps --tail=60 jaeger collector node-app python-app 2>/dev/null || true
  echo "--- jaeger /api/services (what actually landed) ---"
  curl -fsS "http://localhost:16686/api/services" 2>/dev/null && echo || echo "(jaeger /api/services unreachable)"
  docker compose down -v --remove-orphans 2>/dev/null || true
  # The app containers write node_modules / site-packages into the bind-mounted .work as
  # root, so the (non-root) host user can't rm them directly. Fall back to a non-interactive
  # sudo (passwordless on CI runners); never prompt, never fail the run over cleanup.
  rm -rf "$WORK" 2>/dev/null || sudo -n rm -rf "$WORK" 2>/dev/null || true
}
trap cleanup EXIT

# 1. seed throwaway app copies (fixtures stay pristine)
rm -rf "$WORK"; mkdir -p "$WORK/nodejs" "$WORK/python"
cp -R ../../fixtures/nodejs-greenfield/. "$WORK/nodejs/"
cp ../snapshots/instrument/nodejs/tracing.js "$WORK/nodejs/tracing.js"
cp ../snapshots/instrument/nodejs/package.json "$WORK/nodejs/package.json"   # instrumented manifest
cp -R ../../fixtures/python-greenfield/. "$WORK/python/"
cp ../snapshots/instrument/python/tracing.py "$WORK/python/tracing.py"
cp ../snapshots/instrument/python/requirements.txt "$WORK/python/requirements.txt"
# Python entrypoint: import the golden bootstrap (sets up providers as a side effect of
# import), then instrument the pristine fixture's FastAPI `app` without modifying it.
cat > "$WORK/python/e2e_main.py" <<'PY'
import tracing
from app import app
tracing.instrument_fastapi(app)
PY

# 2. up + wait for jaeger health
docker compose up -d
echo "waiting for stack..."
deadline=$(( $(date +%s) + 120 ))
until curl -fsS "http://localhost:16686/" >/dev/null 2>&1; do
  [ "$(date +%s)" -lt "$deadline" ] || { echo "FAIL: jaeger did not become healthy within timeout" >&2; exit 1; }
  sleep 3
done

# 3. drive load from the host against both apps (both ports are published — see
#    docker-compose.yml). Each wait is bounded so CI can't hang.
wait_ready() { # base_url
  local base="$1"
  # 150s: the python-app runs `pip install` (grpcio + otlp proto exporter) inline
  # before serving, which on a cold CI runner can approach 90s alone — 90s was too
  # tight and risked spurious red on the first live run.
  local APP_READY_TIMEOUT_S=150
  local deadline=$(( $(date +%s) + APP_READY_TIMEOUT_S ))
  until curl -fsS "$base/health" >/dev/null 2>&1; do
    [ "$(date +%s)" -lt "$deadline" ] || { echo "FAIL: $base did not become ready within timeout" >&2; exit 1; }
    sleep 2
  done
}

wait_ready "http://localhost:3000"
for i in 1 2 3 4 5; do
  curl -fsS "http://localhost:3000/health" >/dev/null || true
  curl -fsS -XPOST "http://localhost:3000/checkout" -H "content-type: application/json" \
    -d '{"cartId":"c1","userId":"u1"}' >/dev/null || true
  curl -fsS "http://localhost:3000/orders/o1" >/dev/null || true
done

wait_ready "http://localhost:8000"
for i in 1 2 3 4 5; do
  curl -fsS "http://localhost:8000/health" >/dev/null || true
  curl -fsS "http://localhost:8000/inventory/sku-1" >/dev/null || true
  curl -fsS -XPOST "http://localhost:8000/inventory/reserve" -H "content-type: application/json" \
    -d '{"sku":"sku-1","quantity":1,"warehouse":"us-east-1"}' >/dev/null || true
done

# 4. assert (Jaeger reachable on host 16686)
JA="http://localhost:16686"
# Check BOTH services in one run (don't fail-fast on the first) so a single CI run reports
# the status of node AND python, not just whichever is asserted first.
rc=0
POLL_TIMEOUT=40 bash assert-traces.sh --jaeger "$JA" --service checkout-api \
  --expect service.name=checkout-api,service.version=1.4.2,service.namespace=storefront || rc=1
POLL_TIMEOUT=40 bash assert-traces.sh --jaeger "$JA" --service inventory-api \
  --expect service.name=inventory-api,service.version=0.3.1,service.namespace=storefront,deployment.environment.name=e2e || rc=1

if [ "$rc" -eq 0 ]; then
  echo "E2E PASS: traces for both services landed with correct service.* attrs"
else
  echo "E2E FAIL: at least one service's traces did not land — see per-service output above and the trap diagnostics (jaeger /api/services)." >&2
  exit 1
fi
