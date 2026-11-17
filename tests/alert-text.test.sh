#!/usr/bin/env bash
# tests/alert-text.test.sh: offline checks that every generated alert explains itself (#288).
# skills/terraform-patterns/alert-text.json holds, per alert kind, what it means, its likely
# causes and what to check first. This keeps the table well-formed, finds EVERY alert in every
# golden (Grafana rules, Datadog monitors, New Relic conditions, Dash0 check rules) and requires
# each to carry its kind's text, rendered by tests/alert_text_render.py, byte for byte. Whether a
# backend shows the text in a notification is not checked here: no backend is run.
set -uo pipefail
cd "$(dirname "$0")/.."
pass=0; fail=0
check() { if eval "$2"; then echo "PASS: $1"; pass=$((pass+1)); else echo "FAIL: $1"; fail=$((fail+1)); fi; }

problems=$(python3 - <<'PY'
import json, re, sys
sys.path.insert(0, "tests")
from alert_text_render import render
table = json.load(open("skills/terraform-patterns/alert-text.json", encoding="utf-8"))
for kind, t in table["kinds"].items():
    for part in ("meaning", "causes", "check"):
        v = t.get(part) or ""
        if not v.strip():
            print(f"{kind}: no {part}")
        if '"' in v or "\\" in v:
            print(f"{kind}.{part}: a double quote or backslash would break the HCL or YAML string")
        if "—" in v:
            print(f"{kind}.{part}: em dash")
        if "%{" in v or ("${" in v and "${var.service_name}" not in v):
            print(f"{kind}.{part}: a template sequence other than ${{var.service_name}}")
    if "${var.service_name}" not in t.get("meaning", ""):
        print(f"{kind}: the meaning does not name the service")

def kind_of(name):
    n = name.lower()
    if "burn" in n: return "burn_rate"
    if "error-log" in n: return "error_logs"
    if "latency" in n: return "latency"
    if "error" in n: return "error_rate"
    return None

# (golden, backend, block start, how the alert's name is found in the block)
GOLDENS = [
    ("tests/snapshots/grafana/main.tf.snap", "grafana", r"\n  rule \{", r'\n    name\s+= "(.*)"'),
    ("tests/snapshots/grafana-selfhosted/main.tf.snap", "grafana", r"\n  rule \{", r'\n    name\s+= "(.*)"'),
    ("tests/snapshots/datadog/main.tf.snap", "datadog", r'\nresource "datadog_monitor"', r'\n  name\s+= "(.*)"'),
    ("tests/snapshots/newrelic/main.tf.snap", "newrelic", r'\nresource "newrelic_nrql_alert_condition"', r'\n  name\s+= "(.*)"'),
    ("tests/snapshots/dash0/main.tf.snap", "dash0", r'\nresource "dash0_check_rule"', r"- alert: (\w+)_"),
]
total = 0
kinds_in = {}
for path, backend, start, name_re in GOLDENS:
    text = open(path, encoding="utf-8").read()
    # Each block runs to the next top-level resource (or rule): enough to hold its own fields.
    cuts = [m.start() for m in re.finditer(start, text)]
    if not cuts:
        print(f"{path}: no alerts found")
    for i, at in enumerate(cuts):
        end = cuts[i + 1] if i + 1 < len(cuts) else len(text)
        nxt = re.search(r"\nresource ", text[at + 1:end])
        block = text[at:at + 1 + nxt.start()] if nxt else text[at:end]
        m = re.search(name_re, block)
        name = m.group(1) if m else "?"
        kind = kind_of(re.sub(r"(?<=[a-z])(?=[A-Z])", " ", name).replace("Error Log", "error-log"))
        total += 1
        kinds_in.setdefault(path, set()).add(kind)
        if not kind:
            print(f"{path}: alert {name!r} matches no kind in alert-text.json")
            continue
        if "\n".join(render(table, kind, backend)) not in block:
            print(f"{path}: alert {name!r} does not carry the {kind} text from alert-text.json")
# The generator's own list of alerts per backend ("Include: ... <resource> (...)") names the
# same kinds its golden has: a list that promises an alert the golden lacks is how the Grafana
# generator asked for a p99 rule that no golden or test had.
gen = open("agents/terraform-gen.md", encoding="utf-8").read()
for resource, path in [
    ("grafana_rule_group", "tests/snapshots/grafana/main.tf.snap"),
    ("datadog_monitor", "tests/snapshots/datadog/main.tf.snap"),
    ("newrelic_nrql_alert_condition", "tests/snapshots/newrelic/main.tf.snap"),
    ("dash0_check_rule", "tests/snapshots/dash0/main.tf.snap"),
]:
    m = re.search(r"Include:.*?" + resource + r" \(([^)]*)\)", gen)
    if not m:
        print(f"terraform-gen.md: no Include list names {resource} (...)")
        continue
    listed = m.group(1).split(";")[0].lower()
    named = {k for k, words in [("error_rate", ("error rate",)), ("latency", ("latency", "p99")),
                                ("error_logs", ("error-log",))] if any(w in listed for w in words)}
    if named != kinds_in.get(path, set()):
        print(f"terraform-gen.md lists {sorted(named)} for {resource}, the golden has {sorted(kinds_in.get(path, set()))}")
print(f"COUNT {total}")
PY
)
count=$(printf '%s\n' "$problems" | sed -n 's/^COUNT //p')
problems=$(printf '%s\n' "$problems" | grep -v '^COUNT ')
check "alert-text.json is well-formed, every golden alert carries its kind's text, and the generator lists the goldens' alerts" '[ -z "$problems" ] || { printf "  %s\n" "$problems"; false; }'
# 2 Grafana Cloud + 3 self-hosted + 2 Datadog + 3 New Relic + 2 Dash0. A new alert raises this
# number and must arrive with its text.
check "all 12 golden alerts were found (found ${count:-0})" '[ "${count:-0}" = 12 ]'

for g in grafana grafana-selfhosted; do
  f=tests/snapshots/$g/main.tf.snap
  check "$g: the trace-search link searches the service in TraceQL" \
    "grep -qF 'query      = \"{resource.service.name=\\\"\${var.service_name}\\\"}\"' $f"
  check "$g: the link is built from the Grafana URL and the Tempo datasource variable" \
    "grep -qF 'traces_explore_url = \"\${trimsuffix(var.grafana_url, \"/\")}/explore?schemaVersion=1&panes=' $f && grep -q 'variable \"tempo_datasource_uid\"' $f"
done
check "self-hosted Tempo default is the local stack's datasource UID (tempo)" \
  "grep -A3 'variable \"tempo_datasource_uid\"' tests/snapshots/grafana-selfhosted/main.tf.snap | grep -q 'default     = \"tempo\"'"
check "the generator reads alert-text.json instead of writing alert text from memory" \
  "grep -q 'alert-text.json' agents/terraform-gen.md && grep -q 'alert-text.json' skills/terraform-patterns/SKILL.md"
check "the live-apply job can pass a Tempo datasource UID" \
  "grep -q 'GRAFANA_TEMPO_DATASOURCE_UID' .github/workflows/tf-live-validate.yml && grep -q 'TF_VAR_tempo_datasource_uid' tests/tf-live/validate-vendor.sh"

echo "alert-text: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
