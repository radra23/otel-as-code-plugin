#!/usr/bin/env bash
# tests/hooks/zero-services-guard.test.sh
# Locks the #164 contract: a repo whose scan returns no services is answered the same way by every
# command that needs a service, and nothing is written. Before this, /otel-evaluate printed a
# vacuous "no instrumentation detected", /otel-instrument printed an empty candidate list,
# /otel-collector wrote a config for nothing, and /otel-backend built a module around a
# placeholder (<SERVICE_NAME>) or invented (unknown-service) identity whose alerts sat in
# no_data_state = "OK".
set -uo pipefail
cd "$(dirname "$0")/../.."
pass=0; fail=0
check() { if eval "$2"; then echo "PASS: $1"; pass=$((pass+1)); else echo "FAIL: $1"; fail=$((fail+1)); fi; }

INIT="commands/otel-init.md"
TFGEN="agents/terraform-gen.md"
FIX="fixtures/infra-only-repo"

check "otel-init defines the shared Empty scan rule: message, write nothing, exit 0" \
  'grep -qF "**Empty scan (the shared rule).**" "$INIT" && grep -qF "**Write nothing and exit 0.**" "$INIT"'
check "the rule covers a cache that already has services: []" \
  'grep -qF "cache you loaded already has \`services: []\`" "$INIT"'
check "the rule forbids writing the scan to the cache (the .gitignore update is not reached)" \
  'grep -qF "do NOT write the scan to \`.claude/otel-context.json\`" "$INIT"'
check "the rule overrides the commands' 'write what it returns' instruction" \
  'grep -qF "it overrides their \"write what it" "$INIT"'

for c in otel-evaluate otel-instrument otel-collector otel-backend; do
  check "$c applies the Empty scan rule by reference, not by restating it" \
    'grep -qF "apply \`/otel-init\` Step 2'"'"'s \"Empty scan\" rule" "commands/'"$c"'.md"'
done

check "evaluate applies it BEFORE the vacuous 'every service reports no OTel' check" \
  '[ "$(grep -n "Empty scan" commands/otel-evaluate.md | head -1 | cut -d: -f1)" -lt "$(grep -n "Then decide whether there is anything to audit" commands/otel-evaluate.md | cut -d: -f1)" ]'
check "backend applies it BEFORE the unconfirmed-attributes prompt (so --yes cannot get past it)" \
  '[ "$(grep -n "Empty scan" commands/otel-backend.md | head -1 | cut -d: -f1)" -lt "$(grep -n "If \`context.confirmedAt\` is null" commands/otel-backend.md | cut -d: -f1)" ]'
check "instrument says the No candidates branch is not for an empty list" \
  'grep -qF "must not be reached with an empty list" commands/otel-instrument.md'

check "terraform-gen refuses a module with no real service" \
  'grep -qF "## Refuse a module with no real service" "$TFGEN"'
check "terraform-gen forbids both the template placeholder and an invented identity" \
  'grep -qF "Never keep a" "$TFGEN" && grep -qF "unknown-service" "$TFGEN" && grep -qF "<SERVICE_NAME>" "$TFGEN"'

# --- fixture: the issue's repro shape, structurally ---
check "fixture has no application manifest beyond a one-line requirements.txt" \
  '[ "$(find "$FIX" -type f \( -name package.json -o -name pyproject.toml -o -name go.mod -o -name pom.xml -o -name Gemfile -o -name Cargo.toml -o -name "*.csproj" -o -name Dockerfile \) | wc -l)" -eq 0 ] && [ "$(wc -l < "$FIX/scripts/tool/requirements.txt")" -eq 1 ]'
check "fixture's script has no web framework and no server" \
  '! grep -qiE "flask|fastapi|django|uvicorn|http.server|serve_forever|app.run" "$FIX/scripts/tool/run.py"'
check "fixture carries an infrastructure stack and no OTel" \
  'test -f "$FIX/infra/main.tf" && ! grep -rqi opentelemetry "$FIX"'

echo ""
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
