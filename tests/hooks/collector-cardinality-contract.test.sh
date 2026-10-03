#!/usr/bin/env bash
# tests/hooks/collector-cardinality-contract.test.sh
# Guards the #37 contract: /otel-collector's high-cardinality delete_key list must be driven by a
# TYPED field the scanner actually emits (`derived.highCardinalityAttributes`), not by filtering
# conformanceIssues on a `severity: "cardinality"` value that no producer ever writes (which
# silently matched nothing, leaving only the four generic template identifiers protected).
set -uo pipefail
cd "$(dirname "$0")/../.."
pass=0; fail=0

COLLECTOR="commands/otel-collector.md"
SCANNER="agents/repo-context-scanner.md"

# 1. the collector reads the typed field
if grep -q "derived.highCardinalityAttributes" "$COLLECTOR"; then
  echo "PASS: /otel-collector reads derived.highCardinalityAttributes"; pass=$((pass+1))
else
  echo "FAIL: /otel-collector no longer reads derived.highCardinalityAttributes (#37)"; fail=$((fail+1))
fi

# 2. the scanner emits that field (same spelling — this is the producer↔consumer link that drifted)
if grep -q "highCardinalityAttributes" "$SCANNER"; then
  echo "PASS: scanner emits highCardinalityAttributes"; pass=$((pass+1))
else
  echo "FAIL: scanner does not emit highCardinalityAttributes — producer/consumer drift (#37)"; fail=$((fail+1))
fi
# (Reverting to the old severity filter necessarily drops the derived.highCardinalityAttributes
#  read, so check 1 already catches that regression — no brittle "severity=cardinality" grep here,
#  which would false-fire on the docs' own do-NOT guidance.)

# --- #172: the guardrail covers metric data points, not just spans ---------------------------
# A metric dimension is the worst position for an identifier (semconv-discipline's own ranking),
# and the template used to clean spans only. Logs are deliberately NOT guarded: a log record is
# the prescribed home for a per-request identifier.
SKILL="skills/collector-topology/SKILL.md"
SEMCONV="skills/semconv-discipline/SKILL.md"

# delete_key keys under one statements list (trace_statements / metric_statements) of a golden.
stmt_keys() { # file list-name
  awk -v L="$2:" '$1==L{f=1;next} f&&/^    [a-z_]+:/{f=0} f&&/delete_key/{match($0,/"[^"]+"/);print substr($0,RSTART,RLENGTH)}' "$1" | sort | tr '\n' ' '
}
pipeline_procs() { # file pipeline
  awk -v P="    $2:" '$0==P{f=1;next} f&&/processors:/{print;exit}' "$1"
}

for snap in otelcol-agent otelcol-agent-public otelcol-agent-headers; do
  f="tests/snapshots/collector/$snap.yaml.snap"
  tk=$(stmt_keys "$f" trace_statements); mk=$(stmt_keys "$f" metric_statements)
  if [ -n "$tk" ] && [ "$tk" = "$mk" ]; then
    echo "PASS: $snap: metric_statements drop exactly the span drop-list ($tk)"; pass=$((pass+1))
  else
    echo "FAIL: $snap: metric_statements ('$mk') differ from trace_statements ('$tk') (#172)"; fail=$((fail+1))
  fi
  if grep -qF "context: datapoint" "$f"; then
    echo "PASS: $snap: metric statements use the datapoint context"; pass=$((pass+1))
  else
    echo "FAIL: $snap: no datapoint-context statements (#172)"; fail=$((fail+1))
  fi
  for pl in traces metrics; do
    if pipeline_procs "$f" $pl | grep -qF "[memory_limiter, transform, batch]"; then
      echo "PASS: $snap: $pl pipeline runs memory_limiter, transform, batch"; pass=$((pass+1))
    else
      echo "FAIL: $snap: $pl pipeline does not run transform between memory_limiter and batch (#172)"; fail=$((fail+1))
    fi
  done
  if pipeline_procs "$f" logs | grep -qF "[memory_limiter, batch]"; then
    echo "PASS: $snap: logs pipeline is deliberately unguarded"; pass=$((pass+1))
  else
    echo "FAIL: $snap: logs pipeline changed; log records are the prescribed home for identifiers"; fail=$((fail+1))
  fi
done

if grep -qF "metric_statements:" "$SKILL" && grep -qF "context: datapoint" "$SKILL" && grep -qF "**Logs are deliberately not guarded.**" "$SKILL"; then
  echo "PASS: collector-topology template has the metric guardrail and explains why logs are skipped"; pass=$((pass+1))
else
  echo "FAIL: collector-topology template lacks metric_statements, or the log-record rationale (#172)"; fail=$((fail+1))
fi
if grep -qF "BOTH the \`trace_statements\` and" "$COLLECTOR"; then
  echo "PASS: /otel-collector adds derived.highCardinalityAttributes to both lists"; pass=$((pass+1))
else
  echo "FAIL: /otel-collector adds repo-specific keys to spans only (#172)"; fail=$((fail+1))
fi
if ! grep -qF "spans only" "$SEMCONV" && ! grep -qF "cannot reach a metric dimension" "$SEMCONV" && grep -qF "spans and metric data points" "$SEMCONV"; then
  echo "PASS: semconv-discipline no longer says the Collector guardrail cannot reach metrics"; pass=$((pass+1))
else
  echo "FAIL: semconv-discipline still tells every subagent the Collector cannot clean a metric dimension (#172)"; fail=$((fail+1))
fi

echo ""
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
