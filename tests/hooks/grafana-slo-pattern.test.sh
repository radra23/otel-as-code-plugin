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

# --- #167: Grafana Cloud vs self-hosted ---
CMD="commands/otel-backend.md"
GOLD_SH="tests/snapshots/grafana-selfhosted/main.tf.snap"

check "terraform-gen takes grafanaFlavor as an input, Grafana-only, default cloud" \
  'grep -qF "\`grafanaFlavor\` (\`cloud\` | \`self-hosted\`, Grafana only, default \`cloud\`)" "$GEN"'
check "terraform-gen's Grafana section gates grafana_slo on cloud and never emits it for self-hosted" \
  'grep -qF "\`cloud\`: also include \`grafana_slo\`" "$GEN" \
   && grep -qF "\`self-hosted\`: do NOT emit \`grafana_slo\` at all" "$GEN" \
   && grep -qF "Never emit \`grafana_slo\`" "$GEN" \
   && grep -qF "for \`self-hosted\`, even if the caller omits" "$GEN"'
check "terraform-patterns documents the self-hosted burn-rate alternative with the 14.4x SRE constant" \
  'grep -qF "### Self-hosted alternative: burn-rate alert" "$SKILL" && grep -qF "14.4" "$SKILL"'
check "terraform-patterns says grafana_slo is Cloud-only, not assumed for self-hosted" \
  'grep -qi "Cloud only" "$SKILL" && grep -qF "grafana.com/docs/grafana-cloud" "$SKILL"'
check "otel-backend defines --self-hosted and refuses it for any vendor other than grafana" \
  'grep -qF -- "--self-hosted" "$CMD" && grep -qF "only applies to grafana" "$CMD"'
check "otel-backend passes grafanaFlavor to terraform-gen" \
  'grep -qF "grafanaFlavor" "$CMD"'

check "golden grafana-selfhosted snapshot exists and has NO grafana_slo resource" \
  'test -s "$GOLD_SH" && ! grep -q "^resource \"grafana_slo\"" "$GOLD_SH"'
check "golden grafana-selfhosted snapshot has the 14.4x burn-rate rule inside the SAME grafana_rule_group" \
  '[ "$(grep -c "^resource \"grafana_rule_group\"" "$GOLD_SH")" -eq 1 ] \
   && grep -qF "evaluator = { type = \"gt\", params = [14.4] }" "$GOLD_SH"'
check "teeth: the cloud golden still HAS grafana_slo (making sure the self-hosted test above is meaningful)" \
  'grep -q "^resource \"grafana_slo\"" "$GOLD"'

echo ""
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
