#!/usr/bin/env bash
# tests/hooks/grafana-slo-pattern.test.sh
# Locks the #165 contract: the Grafana guidance the generator reads must name every block the
# validated golden grafana_slo carries. The golden has always had destination_datasource, so CI's
# terraform validate was green, while the skill and generator text never mentioned it: whether a
# generated module validated depended on the model going beyond its instructions.
set -uo pipefail
cd "$(dirname "$0")/../.."
pass=0; fail=0
check() { if eval "$2"; then echo "PASS: $1"; pass=$((pass+1)); else echo "FAIL: $1"; fail=$((fail+1)); fi; }

SKILL="skills/terraform-patterns/SKILL.md"
GEN="agents/terraform-gen.md"
GOLD="tests/snapshots/grafana/main.tf.snap"

# Nested block names directly inside the golden's grafana_slo resource.
BLOCKS=$(awk '/^resource "grafana_slo"/{f=1;next} f&&/^}/{f=0} f&&/^  [a-z_]+ *\{/{gsub(/[ {]/,""); print}' "$GOLD")
echo "golden grafana_slo blocks: $(echo $BLOCKS)"

check "the golden grafana_slo has the three blocks this contract is about" \
  'grep -qx query <<<"$BLOCKS" && grep -qx objectives <<<"$BLOCKS" && grep -qx destination_datasource <<<"$BLOCKS"'

SLO_SECTION=$(sed -n '/^### SLO resource/,/^### Key gotchas/p' "$SKILL")
for b in $BLOCKS; do
  check "terraform-patterns SLO pattern includes the golden's \`$b\` block" \
    'grep -qE "^  $b *\{" <<<"$SLO_SECTION"'
done
check "terraform-patterns says omitting a required block fails validate, with the real error text" \
  'grep -qF "Insufficient destination_datasource blocks" "$SKILL"'
check "terraform-patterns defines the shared prometheus_datasource_uid variable the SLO uses" \
  'grep -qF "variable \"prometheus_datasource_uid\"" <<<"$SLO_SECTION" && grep -qF "uid = var.prometheus_datasource_uid" <<<"$SLO_SECTION"'
check "terraform-gen names destination_datasource in its Grafana instructions" \
  'grep -qF "destination_datasource { uid = var.prometheus_datasource_uid }" "$GEN"'

echo ""
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
