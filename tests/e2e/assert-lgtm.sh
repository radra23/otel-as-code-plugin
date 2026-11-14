#!/usr/bin/env bash
# tests/e2e/assert-lgtm.sh
# Local-stack assertion: a trace for --service reached the grafana/otel-lgtm stack that
# /otel-local starts, read back the way the plugin reads it (Tempo through Grafana's datasource
# proxy, explicit start/end). A thin wrapper so CI exercises scripts/lgtm_check.py itself, the
# same code /otel-local runs; --search-json reads a saved response for offline unit testing.
set -euo pipefail
GRAFANA="http://localhost:3000"; SERVICE=""; WAIT=60; SEARCH_JSON=""
while [ $# -gt 0 ]; do
  case "$1" in
    --grafana) GRAFANA="$2"; shift 2;;
    --service) SERVICE="$2"; shift 2;;
    --wait) WAIT="$2"; shift 2;;
    --search-json) SEARCH_JSON="$2"; shift 2;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done
[ -n "$SERVICE" ] || { echo "usage: --service <name> [--grafana <url>] [--wait <s>] [--search-json <file>]" >&2; exit 2; }
CHECK="$(cd "$(dirname "$0")/../.." && pwd)/scripts/lgtm_check.py"
if [ -n "$SEARCH_JSON" ]; then
  exec python3 "$CHECK" traces --service "$SERVICE" --search-json "$SEARCH_JSON"
fi
exec python3 "$CHECK" traces --grafana "$GRAFANA" --service "$SERVICE" --wait "$WAIT"
