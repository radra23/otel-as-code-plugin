#!/usr/bin/env bash
# tests/e2e/fastapi-native.sh
# FastAPI's own telemetry and the generated bootstrap (#300). FastAPI 0.142.0 and later traces
# and measures requests itself, under the stable HTTP names the generated dashboards query;
# opentelemetry-instrumentation-fastapi switches that off and reports the old names unless
# OTEL_SEMCONV_STABILITY_OPT_IN is set. The golden tracing.py therefore calls the package only
# where FastAPI has no telemetry of its own. This runs fixtures/python-greenfield behind it on
# both sides of that line and requires, for one request:
#   - exactly ONE server span, never zero and never two;
#   - on a current FastAPI, with no environment variable: the span and the duration metric come
#     from FastAPI and carry the stable names;
#   - on FastAPI 0.141.1 (the last release without it): the span comes from the package, as before;
#   - with OTEL_AS_CODE_FASTAPI_SOURCE=package on a current FastAPI: the package again, still one span.
# Spans and metrics are read from the console exporters; metrics are flushed when the service is
# stopped. No Docker. Needs Python 3.9+ with venv and network for pip.
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
is() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', expected '$3')"; fi; }

mkdir -p "$WORK/app"
cp "$SRC/fixtures/python-greenfield/app.py" "$SRC/tests/snapshots/instrument/python/tracing.py" \
   "$SRC/tests/snapshots/instrument/python/requirements.txt" "$WORK/app/"
cd "$WORK/app"
printf 'import tracing\nfrom app import app\ntracing.instrument_fastapi(app)\n' > main.py

# run_once <venv> <out>: start the service, reserve stock once, stop it (SIGTERM flushes metrics).
run_once() {
  OTEL_TRACES_EXPORTER=console OTEL_METRICS_EXPORTER=console \
    "$1/bin/uvicorn" main:app --port 8950 --no-access-log > "$2" 2>&1 & APP_PID=$!
  for _ in $(seq 1 60); do curl -fsS http://localhost:8950/health >/dev/null 2>&1 && break; sleep 0.5; done
  curl -fsS -o /dev/null -X POST -H 'Content-Type: application/json' \
    -d '{"sku":"A-1","quantity":2,"warehouse":"w"}' http://localhost:8950/inventory/reserve || bad "the request failed ($2)"
  stop
}
# report <out>: what the console exporters printed about the one POST, as shell assignments.
report() {
  python3 - "$1" <<'PY'
import json, re, sys
text = open(sys.argv[1], encoding="utf-8").read()
decoder = json.JSONDecoder()
servers, metrics, names = [], {}, set()
for m in re.finditer(r"(?m)^\{", text):
    try:
        obj, _ = decoder.raw_decode(text, m.start())
    except json.JSONDecodeError:
        continue
    if "kind" in obj and "name" in obj:
        names.add(obj["name"])
    if obj.get("kind") == "SpanKind.SERVER" and "/inventory/reserve" in obj.get("name", ""):
        servers.append(obj)
    for rm in obj.get("resource_metrics", []):
        for sm in rm.get("scope_metrics", []):
            for metric in sm.get("metrics", []):
                if metric["name"].startswith("http.server.") and "duration" in metric["name"]:
                    metrics[metric["name"]] = (metric.get("unit"), sm["scope"]["name"])
attrs = servers[0].get("attributes", {}) if servers else {}
# The console exporter does not print a span's scope; the child spans say who made the request
# span: FastAPI adds fastapi.endpoint, the package adds "<name> http send".
source = "+".join(sorted(
    label for label, hit in (("fastapi", "fastapi.endpoint" in names),
                             ("package", any(n.endswith(" http send") for n in names))) if hit))
print(f"SERVERS={len(servers)}")
print(f"SOURCE={source or 'unknown'}")
print(f"STATUS_ATTR={'http.response.status_code' if 'http.response.status_code' in attrs else 'http.status_code' if 'http.status_code' in attrs else 'none'}")
print("DURATION='" + " ".join(f"{n}:{u}:{s}" for n, (u, s) in sorted(metrics.items())) + "'")
PY
}

# ---------------------------------------------------------------- current FastAPI
python3 -m venv "$WORK/new"
"$WORK/new/bin/pip" install -q --disable-pip-version-check -r requirements.txt
NEW_VERSION=$("$WORK/new/bin/python" -c 'import fastapi; print(fastapi.__version__)')
"$WORK/new/bin/python" -c 'import fastapi.telemetry' 2>/dev/null \
  && ok "the FastAPI that requirements.txt installs today ($NEW_VERSION) has its own telemetry" \
  || bad "FastAPI $NEW_VERSION has no fastapi.telemetry: this test's premise is gone"
run_once "$WORK/new" new.log; eval "$(report new.log)"
is "FastAPI $NEW_VERSION: one request makes exactly one server span" "$SERVERS" 1
is "FastAPI $NEW_VERSION: that span comes from FastAPI itself, the package is not called" "$SOURCE" fastapi
is "FastAPI $NEW_VERSION: the span carries the stable status attribute, with no environment variable" "$STATUS_ATTR" http.response.status_code
is "FastAPI $NEW_VERSION: the duration metric is the one the dashboards query, in seconds" "$DURATION" "http.server.request.duration:s:fastapi"

# The way back, for a service whose existing dashboards query the old names.
run_once_env() { OTEL_AS_CODE_FASTAPI_SOURCE=package run_once "$@"; }
run_once_env "$WORK/new" forced.log; eval "$(report forced.log)"
is "FastAPI $NEW_VERSION with OTEL_AS_CODE_FASTAPI_SOURCE=package: still exactly one server span" "$SERVERS" 1
is "FastAPI $NEW_VERSION with OTEL_AS_CODE_FASTAPI_SOURCE=package: it comes from the package" "$SOURCE" package

# ---------------------------------------------------------------- the last FastAPI without it
python3 -m venv "$WORK/old"
"$WORK/old/bin/pip" install -q --disable-pip-version-check -r requirements.txt "fastapi==0.141.1"
"$WORK/old/bin/python" -c 'import fastapi.telemetry' 2>/dev/null \
  && bad "FastAPI 0.141.1 was expected to have no telemetry of its own" \
  || ok "FastAPI 0.141.1 has no telemetry of its own"
run_once "$WORK/old" old.log; eval "$(report old.log)"
is "FastAPI 0.141.1: one request makes exactly one server span" "$SERVERS" 1
is "FastAPI 0.141.1: that span comes from the instrumentation package, as before" "$SOURCE" package
is "FastAPI 0.141.1: the package still reports the old status attribute by default (why the opt-in variable exists)" "$STATUS_ATTR" http.status_code

[ "$failed" -eq 0 ] && echo "FASTAPI NATIVE E2E PASS: one server span per request on both sides of FastAPI 0.142.0, stable names by default on the current one" \
  || { echo "FASTAPI NATIVE E2E FAIL"; exit 1; }
