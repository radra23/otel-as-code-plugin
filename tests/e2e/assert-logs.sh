#!/usr/bin/env bash
# tests/e2e/assert-logs.sh
# #1 logs assertion: at least one OTLP log record for --service was received by the collector,
# and (optionally) its body contains --expect-body. With --expect-trace-id, a record that matches
# must also carry a trace ID (32 hex digits, not all zero): the proof that a line logged while
# handling a request is tied to that request's trace. The collector's `file` exporter (added by
# collector-logs-overlay.yaml) writes each received batch as one line of OTLP JSON
# ({"resourceLogs":[...]}), so this reads that file. --file <path> polls it (the collector writes
# asynchronously); --logs-json <path> reads a fixed sample once for offline unit testing. JSON
# parsed with python3 (repo convention).
set -euo pipefail

FILE=""; LOGS_JSON=""; SERVICE=""; EXPECT_BODY=""; EXPECT_TRACE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --file) FILE="$2"; shift 2;;
    --logs-json) LOGS_JSON="$2"; shift 2;;
    --service) SERVICE="$2"; shift 2;;
    --expect-body) EXPECT_BODY="$2"; shift 2;;
    --expect-trace-id) EXPECT_TRACE=1; shift;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done
[ -n "$SERVICE" ] || { echo "usage: --service <name> [--expect-body <substr>] [--expect-trace-id] (--file <path> | --logs-json <path>)" >&2; exit 2; }

# See assert-traces.sh for why the python source is captured into a variable rather than run as
# `python3 - <<'PY'` (the heredoc would be consumed as python3's own stdin, leaving nothing for
# the script to read the piped-in JSON from).
PY_CHECK_SRC=$(cat <<'PY'
import json, os, sys

service = os.environ["SERVICE"]
substr = os.environ.get("EXPECT_BODY", "")
want_trace = os.environ.get("EXPECT_TRACE") == "1"

# The file exporter emits JSON Lines: one ExportLogsServiceRequest ({"resourceLogs":[...]}) per
# line, appended over time. Parse each line independently and search across all of them.
found_service = False
matched = False
traced = False
records = 0
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        obj = json.loads(line)
    except json.JSONDecodeError:
        continue
    for rl in obj.get("resourceLogs", []):
        attrs = {a["key"]: a.get("value", {}) for a in (rl.get("resource", {}).get("attributes") or [])}
        if attrs.get("service.name", {}).get("stringValue") != service:
            continue
        found_service = True
        for sl in rl.get("scopeLogs", []):
            for lr in sl.get("logRecords", []):
                records += 1
                body = (lr.get("body") or {}).get("stringValue", "")
                if not substr or substr in body:
                    matched = True
                    trace_id = lr.get("traceId", "")
                    if len(trace_id) == 32 and set(trace_id) != {"0"}:
                        traced = True

if not found_service:
    print(f"FAIL: no log records with service.name={service}"); sys.exit(1)
if not matched:
    print(f"FAIL: {service} present but no log body containing {substr!r} (saw {records} record(s))"); sys.exit(1)
if want_trace and not traced:
    print(f"FAIL: {service} has a matching log record, but none carries a trace ID"); sys.exit(1)
print(f"OK: {service} emitted a log record" + (f" containing {substr!r}" if substr else ""))
PY
)

check() {  # stdin: OTLP logs JSON Lines. Exit 0 ok / 1 mismatch.
  SERVICE="$SERVICE" EXPECT_BODY="$EXPECT_BODY" EXPECT_TRACE="$EXPECT_TRACE" python3 -c "$PY_CHECK_SRC"
}

if [ -n "$LOGS_JSON" ]; then
  check < "$LOGS_JSON"; exit $?
fi

[ -n "$FILE" ] || { echo "live mode needs --file <path>" >&2; exit 2; }
deadline=$(( $(date +%s) + ${POLL_TIMEOUT:-30} ))
while :; do
  # The file may not exist until the collector flushes its first logs batch — treat absent or
  # not-yet-matching as retryable until the deadline.
  if [ -f "$FILE" ] && check < "$FILE"; then
    exit 0
  fi
  [ "$(date +%s)" -lt "$deadline" ] || { echo "FAIL: no matching log record for $SERVICE within ${POLL_TIMEOUT:-30}s" >&2; exit 1; }
  sleep 2
done
