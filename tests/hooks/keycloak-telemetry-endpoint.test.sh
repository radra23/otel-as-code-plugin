#!/usr/bin/env bash
# tests/hooks/keycloak-telemetry-endpoint.test.sh
# Locks #196: Keycloak 26 shares one OTLP endpoint across traces/logs/metrics
# (KC_TELEMETRY_ENDPOINT), and natively exports logs and metrics over OTLP too, not just
# traces — confirmed against Keycloak's own `start --help-all` / docs, not assumed.
set -uo pipefail
cd "$(dirname "$0")/../.."
pass=0; fail=0
check() { if eval "$2"; then echo "PASS: $1"; pass=$((pass+1)); else echo "FAIL: $1"; fail=$((fail+1)); fi; }

SKILL="skills/deployment-remediation/SKILL.md"
GEN="agents/deployment-remediation-gen.md"

check "skill documents the shared KC_TELEMETRY_ENDPOINT across all three signals" \
  'grep -qF "All three signals share one endpoint" "$SKILL" \
   && grep -qF "KC_TELEMETRY_ENDPOINT" "$SKILL" \
   && grep -qF "is inherited from the \`telemetry-endpoint\` option" "$SKILL"'
check "skill tells the generator to propose KC_TELEMETRY_ENDPOINT, not KC_TRACING_ENDPOINT alone" \
  'grep -qF "Propose \`KC_TELEMETRY_ENDPOINT\`, not \`KC_TRACING_ENDPOINT\`" "$SKILL"'
check "skill's tracing table row is KC_TELEMETRY_ENDPOINT, not the old KC_TRACING_ENDPOINT-only row" \
  'grep -qF "| \`KC_TELEMETRY_ENDPOINT\` | Shared OTLP endpoint for traces, logs and metrics |" "$SKILL"'

check "skill documents native OTLP logs with the opentelemetry-logs Preview feature flag" \
  'grep -qF "KC_TELEMETRY_LOGS_ENABLED=true" "$SKILL" \
   && grep -qF "opentelemetry-logs" "$SKILL" \
   && grep -qi "Preview" "$SKILL"'
check "skill documents native OTLP metrics requiring BOTH the feature flag AND KC_METRICS_ENABLED" \
  'grep -qF "KC_TELEMETRY_METRICS_ENABLED=true" "$SKILL" \
   && grep -qF "opentelemetry-metrics" "$SKILL" \
   && grep -qi "BOTH the \`opentelemetry-metrics\` feature flag" "$SKILL"'
check "skill frames native OTLP logs/metrics as an optional mention, not a required finding, when console/Prometheus already works" \
  'grep -qF "Neither is a finding when the target already" "$SKILL"'
check "skill says the feature flag is a build-time arg, not an env var, so it never lands in the env: diff" \
  'grep -qi "not an env var" "$SKILL"'

check "deployment-remediation-gen's worked example proposes KC_TELEMETRY_ENDPOINT, not KC_TRACING_ENDPOINT" \
  'grep -qF "name: KC_TELEMETRY_ENDPOINT" "$GEN" && ! grep -qF "name: KC_TRACING_ENDPOINT" "$GEN"'
check "deployment-remediation-gen's example mentions the native OTLP logs/metrics option next to the already-configured KC_METRICS_ENABLED line" \
  'grep -qF "KC_METRICS_ENABLED=true — no change needed. Keycloak can also export metrics" "$GEN"'
check "deployment-remediation-gen's Not-proposed section explains WHY it must be the shared endpoint var" \
  'grep -qF "This is the SHARED endpoint for traces," "$GEN"'

echo ""
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
