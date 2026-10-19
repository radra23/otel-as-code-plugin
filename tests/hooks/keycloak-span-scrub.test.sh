#!/usr/bin/env bash
# tests/hooks/keycloak-span-scrub.test.sh
# Locks the #197 contract. /otel-remediate proposes KC_TRACING_ENABLED=true for Keycloak, whose
# HTTP server spans carry url.query verbatim, and Keycloak puts live credentials in query strings
# (action-token key=, OIDC code=). Applying the diff as proposed put replayable credentials into
# the trace backend, so the scrub is a precondition of the diff, in the skill and in the report.
set -uo pipefail
cd "$(dirname "$0")/../.."
pass=0; fail=0
check() { if eval "$2"; then echo "PASS: $1"; pass=$((pass+1)); else echo "FAIL: $1"; fail=$((fail+1)); fi; }

SKILL="skills/deployment-remediation/SKILL.md"
GEN="agents/deployment-remediation-gen.md"
GOLD="tests/snapshots/collector/otelcol-agent-keycloak-scrub.yaml.snap"
SEC=$(sed -n '/^### Tracing exports credentials: scrub before enabling/,/^\*\*Logging\*\*/p' "$SKILL")   # captured once: grep -q + pipefail would race
sk() { grep -qF -- "$1" <<<"$SEC"; }

check "skill has the credentials section, citing the issue" \
  'sk "### Tracing exports credentials: scrub before enabling (#197)"'
check "skill names the credential-bearing query keys" \
  'sk "key=<token>" && sk "code=" && sk "session_state="'
check "skill grounds the claim in the spec version it was checked against, and says who reproduced it" \
  'sk "semantic-conventions v1.44.0" && sk "Reported and reproduced in #197"'
check "skill makes the scrub a precondition of the diff, ahead of enabling tracing" \
  'sk "precondition of the diff" && sk "before tracing is switched on" && sk "must not be applied until"'
check "skill covers the already-enabled case as a live exposure" \
  'sk "**Already enabled?**" && sk "Lead the report with it"'
check "skill raises span volume as a decision for the user, not in the diff" \
  'sk "**Volume is a choice, not a silent default.**" && sk "do not add it to the diff"'
check "the sampler row no longer tells the generator to stay silent about volume" \
  '! grep -qF "only propose overriding these if volume is a stated concern" "$SKILL"'

# The processor the skill shows is the processor the validated golden carries.
skill_stmts=$(grep -E '^ +- delete_key\(attributes, "url\.(query|full)"\)' <<<"$SEC" | sed -E 's/<service\.name>/keycloak-auth/; s/ +/ /g' | sort)
gold_stmts=$(grep -E '^ +- delete_key\(attributes, "url\.(query|full)"\)' "$GOLD" | sed -E 's/ +/ /g' | sort)
check "the skill's scrub statements are exactly the ones the golden validates" \
  '[ -n "$skill_stmts" ] && [ "$skill_stmts" = "$gold_stmts" ]'
check "the golden scopes the scrub to one service by service.name" \
  'grep -q "resource.attributes\[\"service.name\"\] == \"keycloak-auth\"" "$GOLD"'
check "the golden runs the scrub in the traces pipeline, after transform and before batch" \
  'awk "/^    traces:/{f=1;next} f&&/processors:/{print;exit}" "$GOLD" | grep -qF "[memory_limiter, transform, transform/keycloak-scrub, batch]"'
check "the golden is validated by collector-validate.sh" \
  'grep -qF "SCRUB_CONFIG" tests/collector-validate.sh'

# The generator turns it into the report.
check "generator checks whether a scrub already exists, and never reports one it cannot see" \
  'grep -qF "span scrub already exists" "$GEN" && grep -qF "Never report \"scrubbed\" for a Collector you cannot see" "$GEN"'
check "report template has the required scrub section before the already-configured list" \
  '[ "$(grep -n "### Before applying: scrub credentials" "$GEN" | head -1 | cut -d: -f1)" -lt "$(grep -n "^### Already configured" "$GEN" | head -1 | cut -d: -f1)" ]'
check "report template has a Decide section for volume and a three-state scrub status" \
  'grep -qF "### Decide (not in the diff)" "$GEN" && grep -qF "receiving Collector not visible in this repo" "$GEN"'
check "'nothing to propose' cannot hide the exposure when tracing is already on" \
  'grep -qF "Except when \`KC_TRACING_ENABLED\` is already \`true\`" "$GEN" && grep -qF "must never hide it" "$GEN"'

echo ""
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
