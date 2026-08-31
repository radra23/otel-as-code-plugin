#!/usr/bin/env bash
# tests/e2e/assert-traces.sh
# #1 assertion: a trace for --service exists and its resource attrs (Jaeger process tags)
# contain every expected key=value. Live mode polls Jaeger; --traces-json mode reads a saved
# response for offline unit testing. JSON parsed with python3 (repo convention).
set -euo pipefail

JAEGER=""; SERVICE=""; EXPECT=""; TRACES_JSON=""
while [ $# -gt 0 ]; do
  case "$1" in
    --jaeger) JAEGER="$2"; shift 2;;
    --service) SERVICE="$2"; shift 2;;
    --expect) EXPECT="$2"; shift 2;;
    --traces-json) TRACES_JSON="$2"; shift 2;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done
[ -n "$SERVICE" ] && [ -n "$EXPECT" ] || { echo "usage: --service <name> --expect k=v,... (--jaeger <url> | --traces-json <file>)" >&2; exit 2; }

# NOTE: the python source is captured into a variable via `$(cat <<'PY' ... PY)`
# rather than run directly as `python3 - <<'PY'` — the latter feeds the heredoc as
# python3's OWN stdin (its source code), which consumes the stream and leaves
# nothing for sys.stdin.read() inside the script to read the piped-in JSON.
# Capturing the source once and passing it via `-c "$PY_CHECK_SRC"` keeps stdin
# free for the caller's redirect/pipe of the actual traces JSON.
PY_CHECK_SRC=$(cat <<'PY'
import json, os, sys
data = json.load(sys.stdin)
service = os.environ["SERVICE"]
expect = dict(kv.split("=", 1) for kv in os.environ["EXPECT"].split(",") if kv)
traces = data.get("data") or []
if not traces:
    print(f"FAIL: no traces for {service}"); sys.exit(1)
# collect process tags for the target service across the first trace
tags = {}
for proc in (traces[0].get("processes") or {}).values():
    if proc.get("serviceName") == service:
        for t in proc.get("tags") or []:
            tags[t["key"]] = str(t.get("value"))
if not tags:
    print(f"FAIL: no process for service {service}"); sys.exit(1)
for k, v in expect.items():
    if tags.get(k) != v:
        print(f"FAIL: {service} expected {k}={v}, got {tags.get(k)!r}"); sys.exit(1)
print(f"OK: {service} has {', '.join(f'{k}={v}' for k,v in expect.items())}")
PY
)

check() {  # stdin: /api/traces JSON. Args: service, expect. Exit 0 ok / 1 mismatch.
  SERVICE="$1" EXPECT="$2" python3 -c "$PY_CHECK_SRC"
}

if [ -n "$TRACES_JSON" ]; then
  check "$SERVICE" "$EXPECT" < "$TRACES_JSON"; exit $?
fi

[ -n "$JAEGER" ] || { echo "live mode needs --jaeger <url>" >&2; exit 2; }
deadline=$(( $(date +%s) + ${POLL_TIMEOUT:-30} ))
# Jaeger's /api/traces requires a time range (microsecond-epoch start/end). Without it the
# endpoint returns an empty result even when the service's traces exist (as /api/services
# confirms) — the original query omitted the range and so never matched. Use a wide window:
# 1h back to 5min forward, covering spans created during the poll.
_now_us=$(( $(date +%s) * 1000000 ))
_start_us=$(( _now_us - 3600000000 ))
_end_us=$(( _now_us + 300000000 ))
while :; do
  if curl -fsS "$JAEGER/api/traces?service=$SERVICE&limit=1&start=$_start_us&end=$_end_us" 2>/dev/null | check "$SERVICE" "$EXPECT"; then
    exit 0
  fi
  [ "$(date +%s)" -lt "$deadline" ] || { echo "FAIL: no matching trace for $SERVICE within ${POLL_TIMEOUT:-30}s" >&2; exit 1; }
  sleep 2
done
