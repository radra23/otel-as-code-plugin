#!/usr/bin/env bash
# tests/e2e/log-panel.sh
# Proves the Grafana golden's log panel and error-log alert (#279) against the pinned
# grafana/otel-lgtm stack from the golden compose file. fixtures/python-greenfield runs behind
# the golden --experimental bootstrap (the one that exports logs over OTLP), logs one ordinary
# line and then one error, and the golden's OWN two LogQL queries, read out of
# tests/snapshots/grafana/main.tf.snap, are run against the stack's Loki through
# scripts/lgtm_check.py:
#   - the panel query returns both lines, and the request's line carries its trace ID;
#   - the alert query returns NOTHING while the service has logged no error (so its severity
#     filter really filters), and a share between 0 and 1 once it has.
# The alert RULE is not evaluated here, only its query.
# Needs Docker with compose, Python 3.9+ with venv, and network for the image and pip.
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
failed=0
ok() { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; failed=1; }
SNAP="$SRC/tests/snapshots/grafana/main.tf.snap"
SERVICE=log-inventory
# golden_expr <text the expr contains>: one query from the Grafana golden, with the Terraform
# variable replaced by this run's service name.
golden_expr() {
  python3 - "$SNAP" "$1" "$SERVICE" <<'PY'
import re, sys
snap, needle, service = sys.argv[1:4]
for line in open(snap, encoding="utf-8"):
    m = re.match(r'\s*expr\s*=\s*"(.*)"\s*$', line)
    if m and needle in m.group(1) and "service_name=" in m.group(1):
        print(m.group(1).replace('\\"', '"').replace("${var.service_name}", service))
        break
else:
    sys.exit(f"no Loki query containing {needle!r} in {snap}")
PY
}
PANEL=$(golden_expr '{service_name=')
ALERT=$(golden_expr 'count_over_time(')
[ "$PANEL" = "{service_name=\"$SERVICE\"}" ] && ok "the panel query was read out of the golden: $PANEL" || { bad "unexpected panel query: $PANEL"; exit 1; }
echo "alert query: $ALERT"

mkdir -p "$WORK/stack"
cp tests/snapshots/local-stack/otel-local.compose.yaml tests/snapshots/local-stack/otel-local.env "$WORK/stack/"
GRAFANA_PORT=$(sed -nE 's/.*"127\.0\.0\.1:([0-9]+):3000".*/\1/p' "$WORK/stack/otel-local.compose.yaml")
GRAFANA="http://localhost:$GRAFANA_PORT"
(cd "$WORK/stack" && docker compose -f otel-local.compose.yaml up -d)
for _ in $(seq 1 90); do curl -fsS "$GRAFANA/api/health" >/dev/null 2>&1 && break; sleep 2; done
curl -fsS "$GRAFANA/api/health" >/dev/null || { echo "FAIL: Grafana never answered"; exit 1; }
ok "local stack up, Grafana on :$GRAFANA_PORT"
logs() { python3 "$SRC/scripts/lgtm_check.py" logs --grafana "$GRAFANA" "$@"; }
# On a failure, show what Loki does hold for the service, labels included.
dump() { echo "  what Loki holds for $SERVICE:"; logs --expr "{service_name=\"$SERVICE\"}" 2>&1 | sed 's/^/    /'; \
         echo "  label names:"; curl -s "$GRAFANA/api/datasources/proxy/uid/loki/loki/api/v1/labels" | head -c 600; echo; }

mkdir -p "$WORK/py"
cp "$SRC/fixtures/python-greenfield/app.py" "$SRC/tests/snapshots/instrument/python/requirements.txt" "$WORK/py/"
cp "$SRC/tests/snapshots/instrument/python/tracing.experimental.py" "$WORK/py/tracing.py"
cd "$WORK/py"
cat > main.py <<'PY'
import logging

import tracing
from app import app

tracing.instrument_fastapi(app)


@app.get("/boom")
def boom():
    logging.getLogger("inventory").error("stock lookup failed")
    return {"ok": False}
PY
python3 -m venv "$WORK/venv"
"$WORK/venv/bin/pip" install -q --disable-pip-version-check -r requirements.txt
(set -a; . "$WORK/stack/otel-local.env"; set +a; export OTEL_SERVICE_NAME=$SERVICE; exec "$WORK/venv/bin/uvicorn" main:app --port 8940) \
  > app.log 2>&1 & APP_PID=$!
for _ in $(seq 1 30); do curl -fsS http://localhost:8940/health >/dev/null 2>&1 && break; sleep 1; done
curl -fsS http://localhost:8940/health >/dev/null || { bad "the service did not start"; cat app.log; exit 1; }

reserve() { curl -fsS -o /dev/null -X POST -H 'Content-Type: application/json' -d '{"sku":"A-1","quantity":2,"warehouse":"w"}' http://localhost:8940/inventory/reserve; }
reserve; reserve; reserve
if out=$(logs --expr "$PANEL" --contains "reserved sku=A-1" --wait 90); then
  ok "the golden panel query returns the service's log line"
  printf '%s\n' "$out" | grep -Eq 'trace_id=[0-9a-f]{32}' \
    && ok "that line carries its request's trace ID in Loki, which is what links it to the trace" \
    || { bad "the line has no trace_id in Loki"; printf '%s\n' "$out"; }
else
  bad "the golden panel query returned no line"; printf '%s\n' "$out"; dump; cat app.log | tail -20
fi

# No error has been logged yet: the alert query must come back empty, or its filter filters nothing.
if out=$(logs --expr "$ALERT"); then
  bad "the alert query returned data before any error line was logged"; printf '%s\n' "$out"
else
  ok "the golden alert query returns nothing while the service has logged no error"
fi

curl -fsS -o /dev/null http://localhost:8940/boom
if out=$(logs --expr "$PANEL" --contains "stock lookup failed" --wait 90); then
  ok "the golden panel query returns the error line too"
else
  bad "the error line never reached Loki"; printf '%s\n' "$out"; dump
fi
if out=$(logs --expr "$ALERT" --wait 60); then
  share=$(printf '%s\n' "$out" | sed -nE 's/^found: .* latest ([0-9.e+-]+)$/\1/p')
  python3 -c "import sys; v=float(sys.argv[1]); sys.exit(0 if 0 < v < 1 else 1)" "${share:-nan}" \
    && ok "the golden alert query returns the share of error lines ($share)" \
    || { bad "the alert query's value is not a share between 0 and 1"; printf '%s\n' "$out"; }
else
  bad "the golden alert query returned nothing after an error line was logged"; printf '%s\n' "$out"; dump
fi

[ "$failed" -eq 0 ] && echo "LOG PANEL E2E PASS: the Grafana golden's log panel and error-log alert queries return data from Loki" \
  || { echo "LOG PANEL E2E FAIL"; exit 1; }
