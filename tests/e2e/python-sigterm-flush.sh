#!/usr/bin/env bash
# tests/e2e/python-sigterm-flush.sh
# Proves #295 on real servers: with the generated Python bootstrap, a SIGTERM sent half a second
# after the last request still delivers that request's span, even though the batch interval (5 s)
# has not elapsed. Python runs no exit handlers when a process dies from a signal, and uvicorn
# re-raises SIGTERM after its graceful shutdown, so relying on the SDK's exit-time flush dropped
# the last batch on every stop.
#
# Each case starts a fresh OTLP/gRPC sink (otlp-grpc-sink.py) and the golden tracing.py under one
# server, sends one request, sends SIGTERM, and looks for the request's path in what the sink
# received. Cases:
#   uvicorn, uvicorn --workers 2, gunicorn + uvicorn worker   FastAPI (fixtures/python-greenfield)
#   gunicorn sync, waitress                                    Flask, a span made in the route
#   in-flight                                                  uvicorn --workers 2 with a request
#                                                              still running when SIGTERM lands
# Needs python3 with venv, curl and network access to PyPI. No Docker.
set -uo pipefail
cd "$(dirname "$0")"
HERE=$PWD
WORK=$(mktemp -d)
SINK_PID=""; APP_PID=""
cleanup() { [ -n "$SINK_PID" ] && kill -9 "$SINK_PID" 2>/dev/null; [ -n "$APP_PID" ] && kill -9 "$APP_PID" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT
# wait_exit <pid> <seconds>: wait for the process, killing it if it outlives the limit. Sets RC.
wait_exit() {
  local pid="$1" limit="$2" n=0
  while kill -0 "$pid" 2>/dev/null && [ "$n" -lt $((limit * 4)) ]; do sleep 0.25; n=$((n+1)); done
  if kill -0 "$pid" 2>/dev/null; then kill -9 "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; RC=hung; else wait "$pid"; RC=$?; fi
}
free_port() { python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])'; }

# TRACING_PY (an absolute path) swaps in another bootstrap, e.g. tracing.experimental.py.
cp -R ../../fixtures/python-greenfield/. "$WORK/" \
  && cp "${TRACING_PY:-$HERE/../snapshots/instrument/python/tracing.py}" "$WORK/tracing.py" \
  && cp ../snapshots/instrument/python/requirements.txt "$WORK/requirements.txt" \
  || { echo "FAIL: could not seed the app" >&2; exit 1; }
cd "$WORK"
# FastAPI entry: the wiring /otel-instrument documents, plus one slow route for the in-flight case.
cat > main.py <<'PY'
import asyncio

import tracing
from app import app

tracing.instrument_fastapi(app)


@app.get("/slow/{tag}")
async def slow(tag: str):
    await asyncio.sleep(1.5)
    return {"tag": tag}
PY
# Flask entry: the bootstrap alone (no framework instrumentor), with a span made in the route.
cat > flask_main.py <<'PY'
import tracing  # noqa: F401  (the bootstrap)
from flask import Flask
from opentelemetry import trace

app = Flask(__name__)
tracer = trace.get_tracer("sigterm-test")


@app.get("/inventory/<sku>")
def stock(sku):
    with tracer.start_as_current_span(f"stock {sku}"):
        return {"sku": sku}
PY
echo "installing the golden bootstrap's dependencies and the servers..."
python3 -m venv venv || { echo "FAIL: venv" >&2; exit 1; }
venv/bin/pip install -q --disable-pip-version-check -r requirements.txt flask gunicorn uvicorn-worker waitress \
  || { echo "FAIL: pip install" >&2; exit 1; }
B="$WORK/venv/bin"

pass=0; fail=0
# run_case <name> <marker> <request path> <delay before SIGTERM> <expected exit|any> <server command...>
# The marker is a string that only this case's span carries (its path or name); it is in nothing
# else the process exports, the service name included.
run_case() {
  local name="$1" marker="$2" path="$3" delay="$4" want_rc="$5"; shift 5
  local sink_port app_port out="$WORK/out-$marker" rc body
  sink_port=$(free_port); app_port=$(free_port); mkdir -p "$out"
  "$B/python" "$HERE/otlp-grpc-sink.py" "$out" "$sink_port" > "$out/sink.log" 2>&1 & SINK_PID=$!
  for _ in $(seq 1 50); do grep -q "sink on" "$out/sink.log" 2>/dev/null && break; sleep 0.1; done
  local cmd=()
  for a in "$@"; do cmd+=("${a//PORT/$app_port}"); done
  OTEL_EXPORTER_OTLP_ENDPOINT="http://127.0.0.1:$sink_port" OTEL_SERVICE_NAME="sigterm-test" \
    "${cmd[@]}" > "$out/app.log" 2>&1 & APP_PID=$!
  local up=0
  for _ in $(seq 1 60); do
    if curl -fsS "http://127.0.0.1:$app_port/health" >/dev/null 2>&1 \
       || curl -fsS "http://127.0.0.1:$app_port/inventory/warmup" >/dev/null 2>&1; then up=1; break; fi
    sleep 0.25
  done
  if [ "$up" -eq 0 ]; then
    echo "FAIL: $name: the server never answered"; tail -5 "$out/app.log" | sed 's/^/    /'; fail=$((fail+1))
    kill -9 "$APP_PID" "$SINK_PID" 2>/dev/null; pkill -9 -f "$WORK/venv/bin" 2>/dev/null; wait 2>/dev/null; APP_PID=""; SINK_PID=""
    return
  fi
  rm -f "$out"/trace-*.bin                       # anything exported while starting up does not count
  if [ "$delay" = inflight ]; then
    curl -fsS -o "$out/body" "http://127.0.0.1:$app_port$path" & local curl_pid=$!
    sleep 0.4; kill -TERM "$APP_PID"; wait "$curl_pid"; body=$?
  else
    curl -fsS -o "$out/body" "http://127.0.0.1:$app_port$path"; body=$?
    sleep "$delay"; kill -TERM "$APP_PID"
  fi
  wait_exit "$APP_PID" 30; rc=$RC; APP_PID=""
  sleep 0.3
  kill -9 "$SINK_PID" 2>/dev/null; wait "$SINK_PID" 2>/dev/null; SINK_PID=""
  local ok=1 why=""
  [ "$body" -eq 0 ] || { ok=0; why="the request itself failed (curl $body)"; }
  if ! grep -a -q -- "$marker" "$out"/trace-*.bin 2>/dev/null; then ok=0; why="${why:+$why; }its span never reached the sink"; fi
  if [ "$want_rc" != any ] && [ "$rc" != "$want_rc" ]; then ok=0; why="${why:+$why; }exit status $rc, expected $want_rc"; fi
  if [ "$ok" -eq 1 ]; then echo "PASS: $name (exit $rc)"; pass=$((pass+1))
  else echo "FAIL: $name: $why"; tail -5 "$out/app.log" | sed 's/^/    /'; fail=$((fail+1)); fi
}

# 143 = died from SIGTERM: the flush must not change how the process ends.
run_case "uvicorn: the last request's span arrives"                 sku-uvicorn  /inventory/sku-uvicorn  0.5 143 "$B/uvicorn" main:app --port PORT
run_case "uvicorn --workers 2: the last request's span arrives"     sku-workers  /inventory/sku-workers  0.5 any "$B/uvicorn" main:app --port PORT --workers 2
run_case "gunicorn + uvicorn worker: the last request's span arrives" sku-gunivorn /inventory/sku-gunivorn 0.5 0 "$B/gunicorn" -k uvicorn_worker.UvicornWorker main:app -b 127.0.0.1:PORT
run_case "gunicorn sync (Flask): the last request's span arrives"   sku-gunicorn /inventory/sku-gunicorn 0.5 0   "$B/gunicorn" flask_main:app -b 127.0.0.1:PORT
run_case "waitress (Flask): the last request's span arrives"        sku-waitress /inventory/sku-waitress 0.5 143 "$B/waitress-serve" --listen=127.0.0.1:PORT flask_main:app
run_case "uvicorn --workers 2: a request still running at SIGTERM finishes, and its span arrives" \
                                                                    tag-inflight /slow/tag-inflight inflight any "$B/uvicorn" main:app --port PORT --workers 2

# A collector that is down must not hold up requests or the stop: every flush is bounded, and
# under a server that handles SIGTERM itself the signal-time flush runs in the background.
down_case() {
  local app_port dead_port out="$WORK/out-down" t0 took rc
  app_port=$(free_port); dead_port=$(free_port); mkdir -p "$out"
  OTEL_EXPORTER_OTLP_ENDPOINT="http://127.0.0.1:$dead_port" OTEL_SERVICE_NAME="sigterm-test" \
    "$B/uvicorn" main:app --port "$app_port" --workers 2 > "$out/app.log" 2>&1 & APP_PID=$!
  for _ in $(seq 1 60); do curl -fsS "http://127.0.0.1:$app_port/health" >/dev/null 2>&1 && break; sleep 0.25; done
  t0=$(python3 -c 'import time; print(time.time())')
  curl -fsS -o /dev/null "http://127.0.0.1:$app_port/slow/down" & local curl_pid=$!
  sleep 0.4; kill -TERM "$APP_PID"; wait "$curl_pid"; rc=$?
  took=$(python3 -c "import time,sys; print(round(time.time() - float(sys.argv[1]), 1))" "$t0")
  wait_exit "$APP_PID" 30; APP_PID=""
  local total; total=$(python3 -c "import time,sys; print(round(time.time() - float(sys.argv[1]), 1))" "$t0")
  if [ "$rc" -eq 0 ] && python3 -c "import sys; sys.exit(0 if float(sys.argv[1]) < 3.5 and float(sys.argv[2]) < 20 else 1)" "$took" "$total"; then
    echo "PASS: collector down: the in-flight request (1.5 s) finished in ${took}s and the process stopped in ${total}s"; pass=$((pass+1))
  else
    echo "FAIL: collector down: request took ${took}s (curl $rc), stop took ${total}s; expected under 3.5 s and 20 s"; fail=$((fail+1))
  fi
}
down_case

echo
echo "python-sigterm-flush: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
