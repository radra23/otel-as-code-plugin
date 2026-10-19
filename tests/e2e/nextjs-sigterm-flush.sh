#!/usr/bin/env bash
# tests/e2e/nextjs-sigterm-flush.sh
# Proves #173 on a real `next start`: with the generated hook and NEXT_MANUAL_SIG_HANDLE=true, a
# SIGTERM sent half a second after the last request still delivers the spans, even though the
# batch interval (5 s) has not elapsed and the backend takes 200 ms to answer. Next's own SIGTERM
# cleanup exits the process without waiting for OpenTelemetry, which is what used to drop them.
#
# Seeds the pristine nextjs-greenfield fixture + the golden instrumentation files (as run.sh does),
# so it exercises the generator's actual output. Needs node, npm, curl, python3 and network access
# to the npm registry. Usage: bash tests/e2e/nextjs-sigterm-flush.sh
set -uo pipefail
cd "$(dirname "$0")"
HERE=$PWD
WORK=$(mktemp -d)
SINK_PID=""; APP_PID=""
cleanup() { [ -n "$SINK_PID" ] && kill -9 "$SINK_PID" 2>/dev/null; [ -n "$APP_PID" ] && kill -9 "$APP_PID" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT

free_port() { python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])'; }

cp -R ../../fixtures/nextjs-greenfield/. "$WORK/"
cp ../snapshots/instrument/nextjs/instrumentation.js ../snapshots/instrument/nextjs/instrumentation.node.js "$WORK/"
cp ../snapshots/instrument/nextjs/package.json "$WORK/package.json"
cd "$WORK"
echo "installing + building the golden Next.js app..."
npm install --no-audit --no-fund --loglevel=error >/dev/null || { echo "FAIL: npm install" >&2; exit 1; }
npx next build >/dev/null 2>&1 || { echo "FAIL: next build" >&2; exit 1; }

# run_case <name> [ENV=VAL ...]  -> prints the number of OTLP trace POSTs the sink received
run_case() {
  local name=$1; shift
  local sp ap log="$WORK/sink-$name.log"
  sp=$(free_port); ap=$(free_port); : > "$log"
  python3 "$HERE/slow-otlp-sink.py" "$log" "$sp" 0.2 >/dev/null 2>&1 & SINK_PID=$!
  sleep 0.7
  env "$@" OTEL_EXPORTER_OTLP_ENDPOINT="http://127.0.0.1:$sp" OTEL_SERVICE_NAME=web-frontend \
    node node_modules/next/dist/bin/next start -p "$ap" >"$WORK/app-$name.log" 2>&1 & APP_PID=$!
  for _ in $(seq 1 40); do curl -fs "localhost:$ap/api/ping" >/dev/null 2>&1 && break; sleep 1; done
  curl -s "localhost:$ap/api/ping" >/dev/null; curl -s "localhost:$ap/api/ping" >/dev/null
  sleep 0.5
  kill -TERM "$APP_PID"
  for _ in $(seq 1 20); do kill -0 "$APP_PID" 2>/dev/null || break; sleep 0.5; done
  sleep 1.5   # the sink records a POST only after its 200 ms delay
  local n; n=$(grep -c '^/v1/traces' "$log" || true)
  kill -9 "$SINK_PID" "$APP_PID" 2>/dev/null; wait 2>/dev/null; SINK_PID=""; APP_PID=""
  echo "$n"
}

rc=0
fixed=$(run_case fixed NEXT_MANUAL_SIG_HANDLE=true)
if [ "${fixed:-0}" -ge 1 ]; then
  echo "PASS: with NEXT_MANUAL_SIG_HANDLE=true the spans were flushed on SIGTERM ($fixed trace POST(s))"
else
  echo "FAIL: NEXT_MANUAL_SIG_HANDLE=true and the generated hook, but SIGTERM delivered no spans (#173)" >&2; rc=1
fi

# The premise, informational only: Next's default handler used to drop the batch. If a future Next
# stops doing so, say it, but do not fail: this check is about our fix, not about Next.
default=$(run_case default NOOP=1)
if [ "${default:-0}" -ge 1 ]; then
  echo "NOTE: Next's default handler delivered the spans too ($default POST(s)); the NEXT_MANUAL_SIG_HANDLE requirement may no longer be needed on this Next version."
else
  echo "INFO: as documented, without NEXT_MANUAL_SIG_HANDLE the same SIGTERM delivers nothing."
fi
exit $rc
