#!/usr/bin/env bash
# tests/hooks/collector-exporter-auth.test.sh
# Locks the #171 contract. The agent/gateway exporter used to carry no credentials, and a --force
# regeneration deleted hand-added exporters.*.headers / auth with no warning (the receiver-auth
# guard only looked at `authenticator:`). Both fail silently: `otelcol-contrib validate` passes
# and the data is rejected at export time, then dropped from the queue.
set -uo pipefail
cd "$(dirname "$0")/../.."
pass=0; fail=0
check() { if eval "$2"; then echo "PASS: $1"; pass=$((pass+1)); else echo "FAIL: $1"; fail=$((fail+1)); fi; }

CMD="commands/otel-collector.md"
SKILL="skills/collector-topology/SKILL.md"
GOLD="tests/snapshots/collector/otelcol-agent-headers.yaml.snap"
STEP3=$(sed -n '/^## Step 3: Determine output path/,/^## Step 4/p' "$CMD")   # captured once: grep -q + pipefail would race
has3() { grep -qF -- "$1" <<<"$STEP3"; }

check "flag --exporter-header is in the argument hint and the flag list" \
  'sed -n 1,4p "$CMD" | grep -qF -- "--exporter-header" && grep -qF -- "- \`--exporter-header <Name=value>\`" "$CMD"'
check "the flag refuses a literal value (every value must be an \${env:} reference)" \
  'grep -qF "refuse a value with no \`\${env:\` in it" "$CMD"'
check "--force keeps exporter headers/auth on a same-named exporter" \
  'has3 "headers:" && has3 "auth:" && has3 "carry the \`headers:\` and \`auth:\` blocks over verbatim"'
check "--force stops when exporter auth sits on an exporter the new config lacks" \
  'has3 "does not produce" && has3 "--confirm-remove-exporter-auth"'
check "the typed opt-out is documented as a flag and in the argument hint" \
  'grep -qF -- "- \`--confirm-remove-exporter-auth\`" "$CMD" && sed -n 1,4p "$CMD" | grep -qF -- "--confirm-remove-exporter-auth"'
check "a header value that is not an env reference is never printed" \
  'has3 "Never print a header VALUE that is not an"'
check "generation emits the headers block from kept headers and flag entries" \
  'grep -qF "Apply exporter auth (both modes" "$CMD"'
check "Step 6 warns when the exporter carries no credentials" \
  'grep -qF "the exporter sends no credentials" "$CMD"'
check "topology skill documents Exporter auth and the no-literal rule" \
  'grep -qF "## Exporter auth (the outbound hop)" "$SKILL" && grep -qF "never a" "$SKILL"'
check "topology skill states regeneration must not drop it" \
  'grep -qF "Regeneration must not drop it." "$SKILL"'
check "golden with headers exists, uses env references only, and is validated by collector-validate.sh" \
  'test -f "$GOLD" && grep -qF "\${env:BACKEND_AUTH_TOKEN}" "$GOLD" && grep -qF "HEADERS_CONFIG" tests/collector-validate.sh'

echo ""
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
