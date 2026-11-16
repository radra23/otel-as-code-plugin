#!/usr/bin/env bash
# tests/runtime-panels.test.sh: offline checks of the runtime panel row (#277).
# skills/terraform-patterns/runtime-panels.json is the one table the generator reads; this keeps
# it well-formed, keeps each query's stored metric name consistent with the metric's own name,
# kind and unit, and pins the Grafana goldens, the maturity matrix and the e2e job to it. Whether
# Prometheus really stores those names is proven live, by tests/e2e/run.sh.
set -uo pipefail
cd "$(dirname "$0")/.."
pass=0; fail=0
check() { if eval "$2"; then echo "PASS: $1"; pass=$((pass+1)); else echo "FAIL: $1"; fail=$((fail+1)); fi; }
TABLE=skills/terraform-patterns/runtime-panels.json
arp() { bash tests/e2e/assert-runtime-panels.sh "$@"; }

# The table itself. One python pass prints a line per problem; no output means no problem.
problems=$(python3 - "$TABLE" <<'PY'
import json, re, sys
doc = json.load(open(sys.argv[1], encoding="utf-8"))
SUFFIX = {"By": "_bytes", "s": "_seconds"}
for language, lang in doc["languages"].items():
    if not lang.get("label"):
        print(f"{language}: no label")
    if not 3 <= len(lang["panels"]) <= 4 or 24 % len(lang["panels"]):
        print(f"{language}: {len(lang['panels'])} panels (3 or 4 fit the 24-column row)")
    for panel in lang["panels"]:
        where = f"{language} / {panel.get('title')}"
        missing = [k for k in ("title", "metric", "kind", "unit", "stability", "grafanaUnit", "grafana") if not panel.get(k)]
        if missing:
            print(f"{where}: missing {missing}"); continue
        if panel["kind"] not in ("counter", "updowncounter", "gauge", "histogram"):
            print(f"{where}: unknown kind {panel['kind']}")
        if panel["stability"] not in ("stable", "release_candidate", "development"):
            print(f"{where}: unknown stability {panel['stability']}")
        # The name Prometheus stores: dots to underscores, then the unit, then _total on a counter.
        # A unit in braces is an annotation and adds nothing; `1` becomes _ratio on a gauge.
        unit = panel["unit"]
        stored = panel["metric"].replace(".", "_")
        if unit in SUFFIX:
            stored += SUFFIX[unit]
        elif unit == "1" and panel["kind"] == "gauge":
            stored += "_ratio"
        elif not re.fullmatch(r"\{[a-z_]+\}", unit):
            print(f"{where}: unit {unit!r} has no checked suffix rule")
        stored += {"counter": "_total", "histogram": "_count"}.get(panel["kind"], "")
        expr = panel["grafana"]
        if stored + '{job="${var.service_name}"}' not in expr:
            print(f"{where}: the query does not select {stored}{{job=\"${{var.service_name}}\"}}")
        rated = "rate(" in expr
        if rated != (panel["kind"] in ("counter", "histogram")):
            print(f"{where}: rate() belongs on a counter or histogram count, and only there")
        if expr.count("(") != expr.count(")") or expr.count("{") != expr.count("}"):
            print(f"{where}: unbalanced query")
        if "|" in expr or "\n" in expr:
            print(f"{where}: keep the query to one line with no alternation")
for language, reason in doc["none"].items():
    if language in doc["languages"] or not reason:
        print(f"none.{language}: needs a reason and no row")
PY
)
check "the table is well-formed and every query selects the name Prometheus stores for its metric" '[ -z "$problems" ]'
[ -n "$problems" ] && printf '  %s\n' "$problems"

langs=$(python3 -c "import json;print(' '.join(json.load(open('$TABLE'))['languages']))")
check "the table has a row for the five languages whose bootstrap emits runtime metrics" \
  '[ "$langs" = "nodejs python java dotnet go" ]'

# The goldens carry the Node.js row exactly as the table renders it.
row=$(python3 tests/runtime_panels_render.py "$TABLE" nodejs 16)
for snap in tests/snapshots/grafana/main.tf.snap tests/snapshots/grafana-selfhosted/main.tf.snap; do
  check "$snap contains the Node.js runtime row, byte for byte, once" \
    'python3 -c "import sys; s=open(sys.argv[1]).read(); sys.exit(0 if s.count(sys.argv[2]+chr(10))==1 else 1)" "$snap" "$row"'
done
check "the row sits between the HTTP panels and the business panels in the Grafana golden" \
  'python3 -c "
s=open(\"tests/snapshots/grafana/main.tf.snap\").read()
a=s.index(\"p99 latency\"); b=s.index(\"Runtime (Node.js)\"); c=s.index(\"# Business-attribute panels\")
assert a<b<c and \"y = 25 }\" in s[c:] and \"y = 16 }\" not in s[c:]"'
check "a panel on a name that is not stable says so, and a stable one does not" \
  'python3 tests/runtime_panels_render.py "$TABLE" nodejs 16 | grep -c "not yet stable" | grep -qx 4 && ! python3 tests/runtime_panels_render.py "$TABLE" dotnet 16 | grep -q "not yet stable"'
check "three panels fill the row as well as four (Go: w = 8)" \
  'python3 tests/runtime_panels_render.py "$TABLE" go 16 | grep -q "w = 8, x = 16, y = 17"'

# New Relic and Dash0: their queries are derived from the same table by rule, and the goldens
# carry the rendered Node.js block byte for byte. Nothing runs these queries against data.
for backend in newrelic dash0; do
  block=$(python3 tests/runtime_panels_render.py "$TABLE" nodejs 0 $backend)
  check "tests/snapshots/$backend/main.tf.snap contains the derived Node.js runtime block, byte for byte, once" \
    'python3 -c "import sys; s=open(sys.argv[1]).read(); sys.exit(0 if s.count(sys.argv[2]+chr(10))==1 else 1)" tests/snapshots/$backend/main.tf.snap "$block"'
done
check "New Relic: a gauge is averaged, a counter and a histogram are rated, by the metric's own name" \
  'python3 tests/runtime_panels_render.py "$TABLE" python 0 newrelic | grep -qF "SELECT average(\`process.memory.usage\`) FROM Metric" && python3 tests/runtime_panels_render.py "$TABLE" python 0 newrelic | grep -qF "SELECT rate(sum(\`cpython.gc.collections\`), 1 second)" && python3 tests/runtime_panels_render.py "$TABLE" nodejs 0 newrelic | grep -qF "SELECT rate(count(\`v8js.gc.duration\`), 1 second)"'
check "New Relic: a metric with one series per pool is split by it, never averaged across" \
  'python3 tests/runtime_panels_render.py "$TABLE" java 0 newrelic | grep -qF "average(\`jvm.memory.used\`) FROM Metric WHERE service.name = '"'"'\${var.service_name}'"'"' FACET \`jvm.memory.pool.name\` TIMESERIES"'
check "New Relic: three panels fill the 12 columns as well as four" \
  'python3 tests/runtime_panels_render.py "$TABLE" go 0 newrelic | grep -c "width  = 4" | grep -qx 3'
check "Dash0: the Grafana query with the service_name label, and no job label left" \
  'python3 tests/runtime_panels_render.py "$TABLE" java 0 dash0 | grep -qF "query: sum(jvm_memory_used_bytes{service_name=\"\${var.service_name}\"})" && ! python3 tests/runtime_panels_render.py "$TABLE" java 0 dash0 | grep -q "job="'
check "both derived blocks say they were not run against live data" \
  'python3 tests/runtime_panels_render.py "$TABLE" nodejs 0 newrelic | grep -q "were not run against a New Relic account" && [ "$(python3 tests/runtime_panels_render.py "$TABLE" nodejs 0 dash0 | grep -c "was not run against live data")" = 4 ]'
check "Datadog has no runtime row yet, and the generator says so" \
  '! grep -qi "runtime" tests/snapshots/datadog/main.tf.snap && tr "\n" " " < agents/terraform-gen.md | tr -s " " | grep -q "runtime row: none for Datadog yet"'
check "the skill states each backend\x27s derivation rule" \
  'grep -q "^### Runtime page (by the service" skills/terraform-patterns/SKILL.md && grep -q "^### Runtime panels (by the service" skills/terraform-patterns/SKILL.md'

# The maturity matrix, the guidance and the e2e job agree with the table.
check "every language with a row is asserted in the maturity matrix, and every language without one is not" \
  'python3 -c "
import json,re
doc=json.load(open(\"$TABLE\")); m=open(\"skills/language-maturity/SKILL.md\").read()
m=m[m.index(\"## Runtime metrics (#277)\"):]
m=m[:m.index(\"\n## \", 3)]
rows={r.split(\"|\")[1].strip().lower(): r.split(\"|\")[-2].strip() for r in m.splitlines() if r.startswith(\"| \") and not r.startswith(\"| Runtime\")}
name={\"nodejs\":\"node.js\",\"dotnet\":\".net\"}
assert all(rows[name.get(l,l)]==\"yes\" for l in doc[\"languages\"]), rows
assert all(rows[l]==\"no\" for l in doc[\"none\"]), rows"'
for l in $langs; do
  check "the trace-flow e2e job runs the $l row's queries" 'grep -q -- "assert-runtime-panels.sh --grafana \"\$GRAFANA\" --language $l " tests/e2e/run.sh'
done
check "the collector overlay forwards metrics to the lgtm container the compose file defines" \
  'grep -q "exporters: \[otlp, file/metrics, otlphttp/lgtm\]" tests/e2e/collector-logs-overlay.yaml && grep -q "^  lgtm:$" tests/e2e/docker-compose.yml'
check "the skill and the generator both send the reader to the table" \
  'grep -q "runtime-panels.json" skills/terraform-patterns/SKILL.md && grep -q "runtime-panels.json" agents/terraform-gen.md'
check "the generator never falls back to remembered names" 'grep -q "Never fall back to remembered metric names" agents/terraform-gen.md'
check "the table ships in the directory build (it is a tracked file under skills/)" \
  'git ls-files --error-unmatch "$TABLE" >/dev/null 2>&1'

# assert-runtime-panels.sh, offline.
check "--list prints one runnable query per panel with the job filled in" \
  '[ "$(arp --list --language java --job storefront/payments-api | wc -l | tr -d " ")" = 4 ] && arp --list --language java --job storefront/payments-api | grep -qx "sum(jvm_memory_used_bytes{job=\"storefront/payments-api\"})"'
check "no Terraform placeholder is left in a query that is about to run" \
  '! arp --list --language nodejs --job a/b | grep -q "var.service_name"'
check "a language with no row is an error, not an empty pass" \
  '! arp --list --language ruby --job a/b >/dev/null 2>&1'
check "missing arguments are a usage error (exit 2)" 'arp --language go >/dev/null 2>&1; [ $? -eq 2 ]'

echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
