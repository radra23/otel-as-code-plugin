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
check "the generator sends the reader to the skill's section and keeps it to Grafana" \
  'grep -q "Log panel and error-log alert" agents/terraform-gen.md && grep -q "log panel: Grafana only" agents/terraform-gen.md'
check "the sections the new text was inserted before are still there" \
  'grep -q "^## Grafana main.tf$" agents/terraform-gen.md && grep -q "^### Notification routing (contact points)$" "$SKILL"'
check "the e2e reads its queries out of the golden and is wired into CI" \
  'grep -q "golden_expr" tests/e2e/log-panel.sh && grep -q "bash tests/e2e/log-panel.sh" .github/workflows/ci.yml'

echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
