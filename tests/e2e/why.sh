#!/usr/bin/env bash
# tests/e2e/why.sh [--record DIR]
# Proves /otel-why's evidence end to end: the pinned grafana/otel-lgtm stack from the golden
# compose file, the why-checkout fixture (tests/why/app) with the golden Node bootstrap, and the
# probes from tests/why/probes.json applied through scripts/probes.py. For each profile in
# tests/why/profiles.json it sends sequential checkouts, reads the traces back the way /otel-why
# does (scripts/trace_summary.py, Tempo through Grafana's datasource proxy) and asserts:
#   - a planted profile: its planted span ranks first and stands out;
#   - the clean profile: nothing stands out;
#   - afterwards, probes.py remove restores the app byte for byte.
# The model's diagnosis is not asserted; the evidence it must quote is.
# --record DIR also saves each profile's raw traces to DIR/<profile>/ (the offline fixtures).
# Needs Docker with compose, Node 18+, and network access for the image and npm.
set -euo pipefail
cd "$(dirname "$0")/../.."
SRC=$PWD
RECORD=""
[ "${1:-}" = "--record" ] && RECORD=$(cd "$2" && pwd)
REQUESTS=${REQUESTS:-10}
WORK=$(mktemp -d)
APP_PID=""; STUB_PID=""
stop() {
  [ -n "$APP_PID" ] && { kill "$APP_PID" 2>/dev/null || true; wait "$APP_PID" 2>/dev/null || true; }
  [ -n "$STUB_PID" ] && { kill "$STUB_PID" 2>/dev/null || true; wait "$STUB_PID" 2>/dev/null || true; }
  APP_PID=""; STUB_PID=""
}
cleanup() {
  stop
  (cd "$WORK/stack" && docker compose -f otel-local.compose.yaml down -v >/dev/null 2>&1) || true
  rm -rf "$WORK"
}
trap cleanup EXIT

mkdir -p "$WORK/stack" "$WORK/app"
cp tests/snapshots/local-stack/otel-local.compose.yaml tests/snapshots/local-stack/otel-local.env "$WORK/stack/"
cp -R tests/why/app/. "$WORK/app/"
cp tests/snapshots/instrument/nodejs/tracing.js "$WORK/app/tracing.js"
GRAFANA_PORT=$(sed -nE 's/.*"127\.0\.0\.1:([0-9]+):3000".*/\1/p' "$WORK/stack/otel-local.compose.yaml")

(cd "$WORK/stack" && docker compose -f otel-local.compose.yaml up -d)
for _ in $(seq 1 90); do curl -fsS "http://localhost:$GRAFANA_PORT/api/health" >/dev/null 2>&1 && break; sleep 2; done
curl -fsS "http://localhost:$GRAFANA_PORT/api/health" >/dev/null || { echo "FAIL: Grafana never answered"; exit 1; }
echo "PASS: local stack up, Grafana on :$GRAFANA_PORT"

cd "$WORK/app"
npm install --no-audit --no-fund --loglevel=error
cp -R "$WORK/app" "$WORK/app-before"         # the installed, unprobed app, for the restore check
python3 "$SRC/scripts/probes.py" helper --lang nodejs --dir . --root .
python3 "$SRC/scripts/probes.py" apply --spec "$SRC/tests/why/probes.json" --root .

profile() { python3 -c "import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]]$2)" "$SRC/tests/why/profiles.json" "$1"; }
failed=0
for name in $(python3 -c "import json; print(' '.join(json.load(open('$SRC/tests/why/profiles.json'))))"); do
  env_args=$(profile "$name" "['env']" | python3 -c "import ast,sys; print(' '.join(f'{k}={v}' for k,v in ast.literal_eval(sys.stdin.read()).items()))")
  expect=$(profile "$name" "['expect']")
  service="why-$name"
  env $env_args node promotions-stub.js > "stub-$name.log" 2>&1 & STUB_PID=$!
  (set -a; . "$WORK/stack/otel-local.env"; set +a; export OTEL_SERVICE_NAME="$service"; exec env $env_args node -r ./tracing.js index.js) \
    > "app-$name.log" 2>&1 & APP_PID=$!
  for _ in $(seq 1 30); do curl -fsS http://localhost:3000/health >/dev/null 2>&1 && break; sleep 1; done
  for i in $(seq 1 "$REQUESTS"); do
    curl -fsS -X POST -H 'Content-Type: application/json' -d '{"cartId":"cart-1","userId":"u1"}' \
      http://localhost:3000/checkout >/dev/null
  done
  stop                                        # flushes the batch span processor on SIGTERM
  out="$WORK/summary-$name.json"
  save=(); [ -n "$RECORD" ] && save=(--save-dir "$RECORD/$name")
  got=""
  for _ in $(seq 1 30); do
    if python3 "$SRC/scripts/trace_summary.py" --grafana "http://localhost:$GRAFANA_PORT" --service "$service" \
         --route "POST /checkout" --json "${save[@]}" > "$out" 2>/dev/null \
       && [ "$(python3 -c "import json; print(json.load(open('$out'))['traces'])")" -ge "$REQUESTS" ]; then
      got=1; break
    fi
    sleep 3
  done
  [ -n "$got" ] || { echo "FAIL: $name: fewer than $REQUESTS traces reached Tempo"; cat "app-$name.log"; failed=1; continue; }
  verdict=$(python3 - "$out" "$expect" <<'PY'
import json, sys
s = json.load(open(sys.argv[1])); expect = sys.argv[2]
top = s["rows"][0]
if expect == "None":
    print("ok" if not s["stands_out"] else f"bad: expected nothing to stand out, got {top['span']} at {top['share']:.0%}")
else:
    ok = s["stands_out"] and top["name"] == expect
    print("ok" if ok else f"bad: expected {expect} first and standing out, got {top['span']} "
          f"(stands_out={s['stands_out']}, share {top['share']:.0%}, {top['self_ms']} ms)")
PY
)
  if [ "$verdict" = ok ]; then
    echo "PASS: $name: $( [ "$expect" = None ] && echo "nothing stands out" || echo "$expect ranks first and stands out")"
  else
    echo "FAIL: $name: $verdict"; failed=1
  fi
done

python3 "$SRC/scripts/probes.py" remove --root .
rm -f stub-*.log app-*.log
if diff -r "$WORK/app-before" "$WORK/app" >/dev/null; then
  echo "PASS: probes.py remove restored the app byte for byte"
else
  echo "FAIL: the app differs from before the probes"; diff -r "$WORK/app-before" "$WORK/app" | head -20; failed=1
fi
[ "$failed" -eq 0 ] && echo "WHY E2E PASS: every planted span ranked first; the clean app showed nothing"
exit "$failed"
