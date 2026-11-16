#!/usr/bin/env bash
# tests/e2e/assert-runtime-panels.sh
# Runtime panel row (#277): every query the generated Grafana dashboard would chart for one
# language returns data from the stack's Prometheus. The queries are read out of
# skills/terraform-patterns/runtime-panels.json (the table the generator reads), with the
# Terraform variable replaced by the job label this service has, and run through
# scripts/lgtm_check.py, the same checker /otel-local uses. On a failure it prints the runtime
# metric names Prometheus does hold for that job, which is usually the whole diagnosis: a metric
# is stored with dots as underscores, its unit and, for a counter, _total.
#
#   assert-runtime-panels.sh --grafana URL --language LANG --job JOB [--wait SECONDS]
#   assert-runtime-panels.sh --list --language LANG --job JOB        (print the queries, run nothing)
set -euo pipefail
SRC="$(cd "$(dirname "$0")/../.." && pwd)"
TABLE="$SRC/skills/terraform-patterns/runtime-panels.json"

GRAFANA=""; LANGUAGE=""; JOB=""; WAIT=120; LIST=0
while [ $# -gt 0 ]; do
  case "$1" in
    --grafana) GRAFANA="$2"; shift 2;;
    --language) LANGUAGE="$2"; shift 2;;
    --job) JOB="$2"; shift 2;;
    --wait) WAIT="$2"; shift 2;;
    --list) LIST=1; shift;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done
[ -n "$LANGUAGE" ] && [ -n "$JOB" ] || { echo "usage: --language <lang> --job <job> (--grafana <url> | --list)" >&2; exit 2; }

# One line per panel: <names regex>\t<title>\t<query>. The regex covers the metric's first name
# segment, so the failure output shows its neighbours too.
PANELS=$(python3 - "$TABLE" "$LANGUAGE" "$JOB" <<'PY'
import json, sys
table, language, job = sys.argv[1:4]
lang = json.load(open(table, encoding="utf-8"))["languages"].get(language)
if lang is None:
    sys.exit(f"no runtime panels for language {language!r} in {table}")
for panel in lang["panels"]:
    if "${var.service_name}" not in panel["grafana"]:
        sys.exit(f"{panel['title']}: the query does not filter by ${{var.service_name}}")
    prefix = panel["metric"].split(".")[0]
    print(f"{prefix}_.*\t{panel['title']}\t{panel['grafana'].replace('${var.service_name}', job)}")
PY
)

if [ "$LIST" -eq 1 ]; then printf '%s\n' "$PANELS" | cut -f3; exit 0; fi
[ -n "$GRAFANA" ] || { echo "live mode needs --grafana <url>" >&2; exit 2; }

rc=0
while IFS=$'\t' read -r names title expr; do
  if python3 "$SRC/scripts/lgtm_check.py" query --grafana "$GRAFANA" --expr "$expr" --wait "$WAIT" --names "$names"; then
    echo "OK: $LANGUAGE runtime panel \"$title\" has data: $expr"
  else
    echo "FAIL: $LANGUAGE runtime panel \"$title\" returned nothing: $expr"
    echo "  names Prometheus holds for job=\"$JOB\" matching $names:"
    curl -s -G "$GRAFANA/api/datasources/proxy/uid/prometheus/api/v1/query" \
      --data-urlencode "query=count by (__name__) ({__name__=~\"$names\",job=\"$JOB\"})" | head -c 3000; echo
    rc=1
  fi
done <<< "$PANELS"
exit "$rc"
