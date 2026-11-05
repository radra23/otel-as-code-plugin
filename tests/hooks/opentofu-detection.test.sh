#!/usr/bin/env bash
# tests/hooks/opentofu-detection.test.sh
# Locks #166: terraform-gen and /otel-backend must resolve terraform vs tofu rather than
# hard-coding `terraform` — a tofu-only host has no `terraform` binary at all.
set -uo pipefail
cd "$(dirname "$0")/../.."
pass=0; fail=0
check() { if eval "$2"; then echo "PASS: $1"; pass=$((pass+1)); else echo "FAIL: $1"; fail=$((fail+1)); fi; }

GEN="agents/terraform-gen.md"
CMD="commands/otel-backend.md"
SKILL="skills/terraform-patterns/SKILL.md"

check "generator defines the Detect Terraform vs OpenTofu section" \
  'grep -qF "## Detect Terraform vs OpenTofu, before anything else" "$GEN"'
check "generator checks lock-file evidence (registry.opentofu.org) before PATH" \
  'grep -qF "registry.opentofu.org" "$GEN" && grep -qF "Lock-file evidence wins when present" "$GEN"'
check "generator falls back to checking PATH for terraform and tofu" \
  'grep -qF "command -v terraform" "$GEN" && grep -qF "command -v tofu" "$GEN"'
check "generator uses <TF_BIN> in the generation steps, not a hard-coded terraform" \
  'grep -qF "<TF_BIN> -chdir=<output_dir> fmt" "$GEN" \
   && grep -qF "<TF_BIN> -chdir=<output_dir> init" "$GEN" \
   && grep -qF "<TF_BIN> -chdir=<output_dir> validate" "$GEN"'
check "generator uses <TF_BIN> in the main.tf header's Next steps comment" \
  'grep -qF "#   <TF_BIN> init" "$GEN" && grep -qF "#   <TF_BIN> plan" "$GEN" && grep -qF "#   <TF_BIN> apply" "$GEN"'
check "generator uses <TF_BIN> in its returned summary block" \
  'grep -qF "<TF_BIN> fmt:" "$GEN" && grep -qF "<TF_BIN> validate:" "$GEN"'
check "generator's optional schema-verify step also uses the resolved <TF_BIN>, not a literal terraform binary" \
  'grep -qF "The resolved \`<TF_BIN>\` binary" "$GEN"'

# Teeth check: a hard-coded `terraform -chdir=` (the exact pre-#166 bug) must not reappear.
check "teeth: no hard-coded 'terraform -chdir=' remains in the generation steps" \
  '! grep -qF "terraform -chdir=<output_dir>" "$GEN"'
check "teeth: no hard-coded literal 'terraform init'/'terraform plan'/'terraform apply' next-steps remain" \
  '! grep -qE "^\s*(#\s*)?terraform (init|plan|apply)\s*$" "$GEN"'

check "otel-backend defers to the subagent-resolved binary name, not a hard-coded terraform" \
  'grep -qF "<TF_BIN> init" "$CMD" && grep -qF "<TF_BIN> plan" "$CMD" && grep -qF "<TF_BIN> apply" "$CMD" \
   && ! grep -qF "terraform init && terraform plan && terraform apply" "$CMD"'
check "otel-backend explains it mirrors whichever binary the subagent printed" \
  'grep -qi "SAME binary name" "$CMD"'

check "terraform-patterns skill documents the tofu fallback, not a bare terraform fmt/validate instruction" \
  'grep -qF "tofu fmt" "$SKILL" && grep -qF "tofu validate" "$SKILL" && grep -qF "#166" "$SKILL"'

echo ""
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
