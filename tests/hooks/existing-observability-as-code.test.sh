#!/usr/bin/env bash
# tests/hooks/existing-observability-as-code.test.sh
# Locks #168: committed Grafana dashboard/alert-rule JSON that ANOTHER system provisions must not
# be invisible to the auditor or silently duplicated by /otel-backend.
set -uo pipefail
cd "$(dirname "$0")/../.."
pass=0; fail=0
check() { if eval "$2"; then echo "PASS: $1"; pass=$((pass+1)); else echo "FAIL: $1"; fail=$((fail+1)); fi; }

AUDITOR="agents/brownfield-auditor.md"
CMD="commands/otel-backend.md"
FX="fixtures/nodejs-existing-dashboards"

check "brownfield-auditor defines the Existing observability-as-code dimension (EX)" \
  'grep -qF "### 10. Existing observability-as-code (\`EX\`, #168)" "$AUDITOR"'
check "auditor's detection requires BOTH a dashboards/alerts-style path AND real Grafana-shape JSON keys, not path alone" \
  'grep -qF "before trusting a match" "$AUDITOR" \
   && grep -qiF "is not a finding" "$AUDITOR"'
check "auditor extracts what existing coverage already includes (panel/rule titles + metric names)" \
  'grep -qiF "extract what it already covers" "$AUDITOR"'
check "auditor treats existing coverage as informational by default, not a manufactured finding" \
  'grep -qF "Existing observability-as-code working correctly is success, not a finding to manufacture" "$AUDITOR"'
check "EX category is registered in the stable-ID category list" \
  'grep -qF "\`EX\` existing observability-as-code" "$AUDITOR"'
check "auditor's output template shows a worked EX example" \
  'grep -qF "### Existing Observability-as-code" "$AUDITOR" && grep -qF "[EX-" "$AUDITOR"'

check "otel-backend checks for existing observability-as-code beyond its own output_dir (#168)" \
  'grep -qF "Separately check for observability-as-code" "$CMD" \
   && grep -qF "not just \`<output_dir>\`" "$CMD"'
check "otel-backend explicitly defers to the auditor's heuristic rather than reimplementing it" \
  'grep -qF "do not restate or" "$CMD" && grep -qiF "the one place that can drift" "$CMD"'
check "otel-backend warns (non-blocking) rather than refusing when a duplicate-coverage hit is found" \
  'grep -qF "Generating anyway — review whether this duplicates" "$CMD"'

check "nodejs-existing-dashboards fixture matches the issue's own repro shape" \
  'grep -qF "\"panels\":" "$FX/observability/grafana/dashboards/overview.json" \
   && grep -qF "\"targets\":" "$FX/observability/grafana/dashboards/overview.json" \
   && grep -qF "\"rules\":" "$FX/observability/grafana/alerts/api.json" \
   && grep -qF "http_server_request_duration_seconds" "$FX/observability/grafana/dashboards/overview.json" \
   && grep -qF "http_server_request_duration_seconds" "$FX/observability/grafana/alerts/api.json"'
check "nodejs-existing-dashboards fixture is a real Node HTTP service" \
  'grep -qF "\"name\": \"api\"" "$FX/package.json" && grep -qF "app.listen" "$FX/index.js"'

echo ""
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
