#!/usr/bin/env bash
# tests/e2e/assert-metrics.sh
# Runtime-metrics assertion (#277): the collector received at least one metric for --service whose
# name starts with one of the --expect-prefix values (comma-separated, e.g. "nodejs.,v8js."). The
# collector's `file/metrics` exporter (collector-logs-overlay.yaml) writes each received batch as
# one line of OTLP JSON ({"resourceMetrics":[...]}), so this reads that file. --file <path> polls
# it (metrics are exported on an interval); --metrics-json <path> reads a fixed sample once for
# offline unit testing. On failure it lists the metric names that service did send, which is
# usually the whole diagnosis. JSON parsed with python3 (repo convention).
set -euo pipefail

FILE=""; METRICS_JSON=""; SERVICE=""; PREFIXES=""
while [ $# -gt 0 ]; do
  case "$1" in
    --file) FILE="$2"; shift 2;;
    --metrics-json) METRICS_JSON="$2"; shift 2;;
    --service) SERVICE="$2"; shift 2;;
    --expect-prefix) PREFIXES="$2"; shift 2;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done
[ -n "$SERVICE" ] && [ -n "$PREFIXES" ] || { echo "usage: --service <name> --expect-prefix <p1,p2> (--file <path> | --metrics-json <path>)" >&2; exit 2; }

# See assert-traces.sh for why the python source is captured into a variable rather than run as
# `python3 - <<'PY'` (the heredoc would be consumed as python3's own stdin).
PY_CHECK_SRC=$(cat <<'PY'
import json, os, sys

service = os.environ["SERVICE"]
prefixes = tuple(p for p in os.environ["PREFIXES"].split(",") if p)
names = set()
found_service = False
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        obj = json.loads(line)
    except json.JSONDecodeError:
        continue
    for rm in obj.get("resourceMetrics", []):
        attrs = {a["key"]: a.get("value", {}) for a in (rm.get("resource", {}).get("attributes") or [])}
        if attrs.get("service.name", {}).get("stringValue") != service:
            continue
        found_service = True
        for sm in rm.get("scopeMetrics", []):
            for m in sm.get("metrics", []):
                names.add(m.get("name", ""))

hits = sorted(n for n in names if n.startswith(prefixes))
if not found_service:
    print(f"FAIL: no metrics at all with service.name={service}"); sys.exit(1)
if not hits:
    print(f"FAIL: {service} sent no metric starting with {' or '.join(prefixes)}; it sent: {', '.join(sorted(names)) or '(none)'}")
    sys.exit(1)
print(f"OK: {service} emitted {len(hits)} runtime metric(s), e.g. {', '.join(hits[:4])}")
PY
)

check() {  # stdin: OTLP metrics JSON Lines. Exit 0 ok / 1 mismatch.
  SERVICE="$SERVICE" PREFIXES="$PREFIXES" python3 -c "$PY_CHECK_SRC"
}

if [ -n "$METRICS_JSON" ]; then
  check < "$METRICS_JSON"; exit $?
fi

[ -n "$FILE" ] || { echo "live mode needs --file <path>" >&2; exit 2; }
deadline=$(( $(date +%s) + ${POLL_TIMEOUT:-60} ))
while :; do
  # The file does not exist until the collector flushes its first metrics batch, and a service's
  # first export comes one interval after it starts: retry until the deadline.
  last="FAIL: $FILE was never written"
  if [ -f "$FILE" ]; then
    if last=$(check < "$FILE" 2>&1); then echo "$last"; exit 0; fi
  fi
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "$last"
    echo "FAIL: no runtime metric for $SERVICE within ${POLL_TIMEOUT:-60}s" >&2; exit 1
  fi
  sleep 3
done
