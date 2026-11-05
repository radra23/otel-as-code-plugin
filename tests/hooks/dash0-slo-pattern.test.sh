#!/usr/bin/env bash
# tests/hooks/dash0-slo-pattern.test.sh
# Locks #174: dash0_slo now exists in the provider (1.19.0); the generator must know its real,
# non-configurable constraints (confirmed against Dash0's own SLO API docs, not the Terraform
# schema alone — slo_yaml is an opaque string to Terraform) rather than improvising a shape per
# run.
set -uo pipefail
cd "$(dirname "$0")/../.."
pass=0; fail=0
check() { if eval "$2"; then echo "PASS: $1"; pass=$((pass+1)); else echo "FAIL: $1"; fail=$((fail+1)); fi; }

SKILL="skills/terraform-patterns/SKILL.md"
GEN="agents/terraform-gen.md"
GOLD="tests/snapshots/dash0/main.tf.snap"

check "terraform-patterns defines the dash0_slo SLO resource section" \
  'grep -qF "### SLO resource (\`dash0_slo\`, #174)" "$SKILL"'
check "terraform-patterns documents the fixed 28d window and the 400-rejection for anything else" \
  'grep -qF "duration: 28d" "$SKILL" && grep -qiE "rejected with \`?400\`?" "$SKILL" \
   && grep -qF "NOT configurable" "$SKILL"'
check "terraform-patterns documents Occurrences budgeting and exactly-one-objective" \
  'grep -qF "budgetingMethod: Occurrences" "$SKILL" && grep -qiF "Exactly one objective" "$SKILL"'
check "terraform-patterns says never offer a configurable window for this resource" \
  'grep -qi "do not offer a \`window\` variable" "$SKILL"'
check "terraform-patterns uses the service_name label (Dash0 convention), not job, in the SLO ratioMetric" \
  'SLO_SECTION=$(sed -n "/### SLO resource (\`dash0_slo\`/,/^### /p" "$SKILL"); \
   echo "$SLO_SECTION" | grep -qF "service_name=" && ! echo "$SLO_SECTION" | grep -qE "\{job="'
check "terraform-gen's Dash0 Include list names dash0_slo and the fixed-window constraint" \
  'grep -qF "\`dash0_slo\` (availability SLO, #174)" "$GEN" && grep -qF "never offer a configurable window" "$GEN"'

check "golden dash0 snapshot has a dash0_slo resource" \
  'grep -q "^resource \"dash0_slo\"" "$GOLD"'
check "golden dash0_slo uses OpenSLO v1, Occurrences budgeting, and the fixed 28d rolling window" \
  'SLO_BLOCK=$(awk "/^resource \"dash0_slo\"/{f=1} f{print} f&&/^}/{exit}" "$GOLD"); \
   echo "$SLO_BLOCK" | grep -qF "apiVersion: openslo.com/v1" \
   && echo "$SLO_BLOCK" | grep -qF "budgetingMethod: Occurrences" \
   && echo "$SLO_BLOCK" | grep -qF "duration: 28d" \
   && echo "$SLO_BLOCK" | grep -qF "isRolling: true"'
check "golden dash0_slo has exactly one objectives entry (the hard single-objective constraint)" \
  '[ "$(awk "/^resource \"dash0_slo\"/{f=1} f&&/^}/{exit} f" tests/snapshots/dash0/main.tf.snap | grep -c "displayName:")" -eq 1 ]'
check "golden dash0_slo filters by service_name, not job (Dash0 convention)" \
  'SLO_BLOCK=$(awk "/^resource \"dash0_slo\"/{f=1} f{print} f&&/^}/{exit}" "$GOLD"); \
   echo "$SLO_BLOCK" | grep -qF "service_name=" && ! echo "$SLO_BLOCK" | grep -qE "\{job="'
check "golden dash0_slo's metadata.name uses the DNS-1123 resource_name_slug, same as dash0_check_rule" \
  'grep -qF "\${local.resource_name_slug}-availability" "$GOLD"'

echo ""
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
