#!/usr/bin/env bash
# tests/log-panel.test.sh: offline checks of the Grafana log panel and error-log alert (#279).
# The two LogQL queries are written once in terraform-patterns; both Grafana goldens must carry
# exactly those, with the variables and the alert settings the guidance describes. Whether Loki
# agrees with the queries is proven live, by tests/e2e/log-panel.sh.
set -uo pipefail
cd "$(dirname "$0")/.."
pass=0; fail=0
check() { if eval "$2"; then echo "PASS: $1"; pass=$((pass+1)); else echo "FAIL: $1"; fail=$((fail+1)); fi; }
SKILL=skills/terraform-patterns/SKILL.md
# skill_query <Panel|Alert>: the query in backticks on that bullet of the skill's section.
skill_query() { awk '/^### Log panel and error-log alert/{on=1;next} on&&/^### /{exit} on' "$SKILL" | sed -nE "s/^- $1: \`(.*)\`\$/\1/p"; }
# golden_queries <snap>: every Loki query in the golden, unescaped, one per line.
golden_queries() { sed -nE 's/^ *expr *= *"(.*)"$/\1/p' "$1" | grep 'service_name=' | sed 's/\\"/"/g'; }
PANEL=$(skill_query Panel); ALERT=$(skill_query Alert)

check "the skill states the panel query and the alert query" '[ -n "$PANEL" ] && [ -n "$ALERT" ]'
check "the panel query selects the service by Loki's service_name label, with the bare name" \
  '[ "$PANEL" = "{service_name=\"\${var.service_name}\"}" ]'
check "the alert filters severity by number (17 and up), never by text" \
  'printf "%s" "$ALERT" | grep -qF "| severity_number >= 17 [5m]" && ! printf "%s" "$ALERT" | grep -qi "severity_text\|detected_level\|=~"'
check "the alert is a share: error lines over all lines, the same selector on both sides" \
  '[ "$(printf "%s" "$ALERT" | grep -oF "{service_name=\"\${var.service_name}\"}" | wc -l | tr -d " ")" = 2 ] && printf "%s" "$ALERT" | grep -qF ")) / sum(count_over_time("'
check "no log query uses the Prometheus job label" '! printf "%s\n%s" "$PANEL" "$ALERT" | grep -q "job="'

for snap in tests/snapshots/grafana/main.tf.snap tests/snapshots/grafana-selfhosted/main.tf.snap; do
  check "$snap carries exactly the skill's two queries" \
    '[ "$(golden_queries $snap)" = "$(printf "%s\n%s" "$PANEL" "$ALERT")" ]'
  check "$snap: the log panel is the last panel and names the Loki datasource" \
    'python3 -c "
import re,sys
s=open(sys.argv[1]).read()
d=s[s.index(\"resource \\\"grafana_dashboard\\\"\"):s.index(\"resource \\\"grafana_rule_group\\\"\")]
titles=re.findall(r\"\n        title +=\s*\\\"(.*)\\\"\", d)
assert titles[-1]==\"Logs\", titles
p=d[d.rindex(\"title       = \\\"Logs\\\"\"):]
assert \"type        = \\\"logs\\\"\" in p and \"datasource  = { type = \\\"loki\\\", uid = var.loki_datasource_uid }\" in p
ys=[int(y) for y in re.findall(r\"y = (\d+) }\", d)]
assert ys[-1]==max(ys) and ys[-1]>=ys[-2]+8, ys
" $snap'
  check "$snap: the alert reads its threshold from the variable and treats no data as healthy" \
    'python3 -c "
import sys
s=open(sys.argv[1]).read()
r=s[s.index(\"High error-log share\"):]
r=r[:r.index(\"\n  }\n\")]
assert \"no_data_state  = \\\"OK\\\"\" in r and \"params = [var.error_log_ratio_threshold]\" in r
assert r.count(\"datasource_uid = var.loki_datasource_uid\")==1 and r.count(\"datasource_uid = \\\"__expr__\\\"\")==2
assert \"type       = \\\"reduce\\\"\" in r and \"type       = \\\"threshold\\\"\" in r
" $snap'
  check "$snap declares both variables, the threshold defaulting to 5%" \
    'grep -q "^variable \"loki_datasource_uid\" {$" $snap && grep -A3 "^variable \"error_log_ratio_threshold\" {$" $snap | grep -q "default     = 0.05"'
done
check "the Loki datasource default is Grafana Cloud's for cloud and loki for self-hosted" \
  'grep -A3 "^variable \"loki_datasource_uid\"" tests/snapshots/grafana/main.tf.snap | grep -q "\"grafanacloud-logs\"" && grep -A3 "^variable \"loki_datasource_uid\"" tests/snapshots/grafana-selfhosted/main.tf.snap | grep -q "default     = \"loki\""'
check "the panel says when it will be empty" \
  'grep -q "Empty until the service exports its logs over OTLP" tests/snapshots/grafana/main.tf.snap'
check "the generator sends the reader to the skill's sections, Datadog's included" \
  'grep -q "Log panel and error-log alert" agents/terraform-gen.md && grep -q "stream and error-log monitor" agents/terraform-gen.md && ! grep -q "log panel: none for Datadog" agents/terraform-gen.md'
# New Relic and Dash0: written from each vendor's documentation, pinned to the skill, run nowhere.
NR=tests/snapshots/newrelic/main.tf.snap; D0=tests/snapshots/dash0/main.tf.snap
# backend_query <heading> <bullet prefix>: the query in backticks on that bullet of that section.
backend_query() { awk -v h="$1" '$0==h{on=1;next} on&&/^### /{exit} on' "$SKILL" | grep -F -- "$2" | head -1 | sed -E 's/^[^`]*`([^`]*)`.*$/\1/'; }
NR_ERR="SELECT filter(count(*), WHERE severity.number >= 17) / count(*) FROM Log WHERE service.name = '\${var.service_name}'"
check "the skill states New Relic's error-share query, by severity number" \
  'awk "/^### Logs page and error-log alert/{on=1;next} on&&/^### /{exit} on" "$SKILL" | grep -qF "$NR_ERR"'
check "the New Relic golden uses that query in the alert, and with TIMESERIES on the Logs page" \
  'grep -qF "query = \"$NR_ERR\"" $NR && grep -qF "query      = \"$NR_ERR TIMESERIES\"" $NR'
check "the New Relic alert reads its threshold from the variable, which defaults to 5%" \
  'sed -n "/newrelic_nrql_alert_condition\" \"error_logs\"/,/^}/p" $NR | grep -q "threshold             = var.error_log_ratio_threshold" && grep -A3 "^variable \"error_log_ratio_threshold\"" $NR | grep -q "default     = 0.05"'
check "the New Relic log table selects the documented OTLP attributes" \
  'grep -qF "SELECT timestamp, severity.text, message, trace.id FROM Log WHERE service.name = " $NR && grep -qF "SELECT timestamp, severity.text, message, trace.id FROM Log" "$SKILL"'
check "the Logs page is the last page of the New Relic dashboard and says it was not run" \
  'python3 -c "
import re,sys
s=open(sys.argv[1]).read()
d=s[s.index(\"resource \\\"newrelic_one_dashboard\\\"\"):s.index(\"resource \\\"newrelic_service_level\\\"\")]
pages=re.findall(r\"\n  page \{\n    name = \\\"(.*)\\\"\", d)
assert pages[0]==\"Overview\" and pages[1].startswith(\"Runtime (\") and pages[-1]==\"Logs\", pages
assert \"were not run against a New Relic account\" in d[d.rindex(\"name = \\\"Logs\\\"\"):]
" $NR'
D0_Q='sum by (otel_log_severity_text) (increase({otel_metric_name="dash0.logs", service_name="${var.service_name}"}[5m]))'
check "the skill states Dash0's log-volume query and the golden carries exactly it, as the last panel" \
  'grep -qF -- "- \`$D0_Q\`" "$SKILL" && grep -qF "query: $D0_Q" $D0 && [ "$(sed -n "/^resource \"dash0_dashboard\"/,/^  YAML$/p" $D0 | grep -E "^        [a-zA-Z0-9]+:$" | tail -1 | tr -d " :")" = logVolume ]'
check "Dash0 gets no error-log alert, and the skill says why" \
  '[ "$(grep -c "^resource \"dash0_check_rule\"" $D0)" = 2 ] && ! grep -qi "error.log\|dash0.logs.*>" <(sed -n "/dash0_check_rule/,\$p" $D0) && grep -q "No error-log alert for Dash0" "$SKILL"'
# Datadog: written from its OTLP log mapping and the provider schema, pinned to the skill, run nowhere.
DD=tests/snapshots/datadog/main.tf.snap
DD_SEC='### Log stream and error-log monitor (#279)'
DD_ALL='service:${var.service_name}'
DD_ERR='service:${var.service_name} status:(error OR critical OR alert OR emergency)'
check "the skill states Datadog's three log searches" \
  '[ "$(backend_query "$DD_SEC" "- Log stream")" = "$DD_ALL" ] && [ "$(backend_query "$DD_SEC" "- Error lines")" = "$DD_ERR" ] && [ "$(backend_query "$DD_SEC" "- All lines")" = "$DD_ALL" ]'
check "the Datadog log stream is the dashboard's last widget, searches the service and says it was not run" \
  'python3 -c "
import re,sys
s=open(sys.argv[1]).read()
d=s[s.index(\"resource \\\"datadog_dashboard\\\"\"):s.index(\"resource \\\"datadog_monitor\\\"\")]
kinds=re.findall(r\"\n    (\w+_definition) \{\", d)
assert kinds[-1]==\"log_stream_definition\" and kinds.count(\"log_stream_definition\")==1, kinds
w=d[d.index(\"log_stream_definition\"):]
assert \"title               = \\\"Logs\\\"\" in w and \"query               = \\\"service:\${var.service_name}\\\"\" in w
assert \"not run against a Datadog account\" in w and \"Empty until the service exports its logs over OTLP\" in w
" $DD'
check "the Datadog error-log monitor is a share of the two searches, over 5 minutes, at the variable" \
  'python3 -c "
import sys
s=open(sys.argv[1]).read()
m=s[s.index(\"resource \\\"datadog_monitor\\\" \\\"error_logs\\\"\"):]
m=m[:m.index(\"\n}\n\")]
err,allq=sys.argv[2],sys.argv[3]
assert \"type    = \\\"log alert\\\"\" in m
assert \"query   = \\\"formula(\\\\\\\"errors / total\\\\\\\").last(\\\\\\\"5m\\\\\\\") > \${var.error_log_ratio_threshold}\\\"\" in m, m
assert m.count(\"data_source = \\\"logs\\\"\")==2 and m.count(\"aggregation = \\\"count\\\"\")==2
assert \"name        = \\\"errors\\\"\" in m and \"name        = \\\"total\\\"\" in m
assert m.count(\"query = \\\"\"+err+\"\\\"\")==1 and m.count(\"query = \\\"\"+allq+\"\\\"\")==1
assert \"critical = var.error_log_ratio_threshold\" in m
assert \"on_missing_data\" not in m and \"notify_no_data\" not in m
" $DD "$DD_ERR" "$DD_ALL"'
check "the Datadog threshold variable defaults to 5%, and its monitor query is in the skill" \
  'grep -A3 "^variable \"error_log_ratio_threshold\"" $DD | grep -q "default     = 0.05" && grep -qF "formula(\\\"errors / total\\\").last(\\\"5m\\\") > \${var.error_log_ratio_threshold}" "$SKILL"'
check "the skill says why Datadog filters by status and what it misses" \
  'grep -q "Why status and not the number" "$SKILL" && grep -q "SEVERE" "$SKILL"'

# From a trace to its logs (#279): tests/e2e/trace_link.py builds the LogQL the stack's Tempo
# datasource link (tracesToLogsV2) builds. The saved datasource is the shape grafana/otel-lgtm
# 0.41.1 provisions (its $$ escapes already resolved, as Grafana's API returns them).
TL=tests/e2e/trace_link.py
tl_ds=$(mktemp); tl_bad=$(mktemp); tl_none=$(mktemp)
printf '%s' '{"uid":"tempo","jsonData":{"tracesToLogsV2":{"customQuery":true,"datasourceUid":"loki","query":"{${__tags}} | trace_id = \"${__trace.traceId}\"","tags":[{"key":"service.name","value":"service_name"}]}}}' > "$tl_ds"
sed 's/"service.name"/"k8s.pod.name"/' "$tl_ds" > "$tl_bad"
printf '%s' '{"uid":"tempo","jsonData":{}}' > "$tl_none"
check "trace_link.py renders the link the way Grafana does: tag mapped to the Loki label, trace ID filled in" \
  '[ "$(python3 $TL query --service svc --trace-id 0af7651916cd43dd8448eb211c80319c --datasource-json "$tl_ds")" = "$(printf "loki\n{service_name=\"svc\"} | trace_id = \"0af7651916cd43dd8448eb211c80319c\"")" ]'
check "trace_link.py refuses a tag whose value it does not know, and a datasource with no link" \
  '! python3 $TL query --service svc --trace-id 0af7651916cd43dd8448eb211c80319c --datasource-json "$tl_bad" 2>/dev/null && ! python3 $TL query --service svc --trace-id 0af7651916cd43dd8448eb211c80319c --datasource-json "$tl_none" 2>/dev/null'
check "the e2e starts from a trace found in Tempo, reads the link from the running Grafana, and checks another trace ID finds nothing" \
  'e=tests/e2e/log-panel.sh; a=$(grep -n "link trace-id --grafana" $e | cut -d: -f1); b=$(grep -n "link query --grafana \"\$GRAFANA\" --service \"\$SERVICE\" --trace-id \"\$tid\"" $e | cut -d: -f1); [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ] && grep -q "trace-id 0123456789abcdef0123456789abcdef" $e && ! grep -q "datasource-json" $e'
rm -f "$tl_ds" "$tl_bad" "$tl_none"

check "the sections the new text was inserted before are still there" \
  'grep -q "^## Grafana main.tf$" agents/terraform-gen.md && grep -q "^### Notification routing (contact points)$" "$SKILL"'
check "the e2e reads its queries out of the golden and is wired into CI" \
  'grep -q "golden_expr" tests/e2e/log-panel.sh && grep -q "bash tests/e2e/log-panel.sh" .github/workflows/ci.yml'

echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
