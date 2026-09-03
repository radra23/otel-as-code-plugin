#!/usr/bin/env bash
# tests/hooks/dogfooding-regression.test.sh
# Locks three dogfounding fixes that live in PROMPT / GOLDEN text — not in executable code, so a
# later edit to the scanner prompt or a golden could silently delete them and no other test would
# notice. Each check ties the authored RULE to the FIXTURE / golden that exercises it (the
# freshness-contract pattern): if either half is removed or they drift apart, this fails.
#   #91 — a Blazor WASM project must classify runtime: browser (not server-side dotnet).
#   #94 — a .NET project with no host builder must be generatorSupported: false (inScope stays true).
#   #99 — generated resource identifiers must sanitize npm-scoped service names (service_slug),
#         while query filters keep the raw service.name.
#   #102/#103/#104 — three live-apply-verified Dash0 bugs: dash0_dataset must never default to
#         "production"; a folder-path annotation needs a leading '/'; the auth token needs
#         management/write scope, not ingestion-only.
#   #109 — dash0_check_rule's check_rule_yaml must be a full PrometheusRule document (one group,
#         one rule), not a flat alert body — caught by the first live tf-live-validate run.
set -uo pipefail
cd "$(dirname "$0")/../.."
pass=0; fail=0
check() { if eval "$2"; then echo "PASS: $1"; pass=$((pass+1)); else echo "FAIL: $1"; fail=$((fail+1)); fi; }

SCANNER="agents/repo-context-scanner.md"
BLAZOR="fixtures/dotnet-blazor-wasm"
TESTPROJ="fixtures/dotnet-testproject"

# --- #91: Blazor WASM → browser ------------------------------------------------------------------
# The scanner's browser rule must name the WASM SDK, AND the fixture must carry it — the pair keeps
# the rule and its repro in lockstep. If the rule is deleted, browser classification reverts to the
# subagent guessing (the bug); if the fixture loses the SDK, it stops reproducing.
check "#91 scanner browser rule names the Blazor WASM SDK" \
  'grep -q "Microsoft.NET.Sdk.BlazorWebAssembly" "$SCANNER"'
check "#91 blazor fixture carries that exact SDK (repro intact)" \
  'grep -q "Microsoft.NET.Sdk.BlazorWebAssembly" "$BLAZOR/portal-web.csproj"'
check "#91 scanner dotnet row excludes Blazor (cross-ref)" \
  'grep -qiE "except.*blazor|blazor.*(browser|see that row)" "$SCANNER"'
check "#91 framework enum gained a .NET value (blazor)" \
  'grep -q "blazor" "$SCANNER"'

# --- #94: no host builder → generatorSupported:false ---------------------------------------------
# The scanner's dotnet generatorSupported gate must name host-builder evidence, AND the test
# fixture must be a hostless test project.
check "#94 gate names Microsoft.NET.Sdk.Web host evidence" \
  'grep -q "Microsoft.NET.Sdk.Web" "$SCANNER"'
check "#94 gate names a host-builder call (IHostBuilder / CreateApplicationBuilder)" \
  'grep -qE "IHostBuilder|CreateApplicationBuilder|WebApplication.CreateBuilder" "$SCANNER"'
check "#94 gate accounts for IsTestProject" \
  'grep -q "IsTestProject" "$SCANNER"'
check "#94 test fixture IS a test project" \
  'grep -q "IsTestProject" "$TESTPROJ/Fillr.WebTests.csproj"'
check "#94 test fixture has NO host builder (the disqualifying fact)" \
  '! grep -rqE "WebApplication.CreateBuilder|Host.CreateApplicationBuilder|Host.CreateDefaultBuilder|IHostBuilder" "$TESTPROJ"'

# Both new .NET fixtures are greenfield — no OTel *packages* (a prose mention in a comment is
# fine; what matters is no dependency), so they exercise the classifier, not coexistence.
check "new .NET fixtures declare no OTel package reference (greenfield)" \
  '! grep -rqiE "Include=\"OpenTelemetry|@opentelemetry" "$BLAZOR" "$TESTPROJ"'

# --- #99: npm-scoped service name sanitized in identifiers, raw in queries ----------------------
for g in dash0 grafana; do
  SNAP="tests/snapshots/$g/main.tf.snap"
  check "#99 $g golden defines a service_slug local" \
    'grep -q "service_slug" "'"$SNAP"'"'
  check "#99 $g golden uses local.service_slug in an identifier position" \
    'grep -q "local.service_slug" "'"$SNAP"'"'
  # The split is the point: identifiers slugged, but the raw var.service_name MUST survive in
  # query filters / titles (grafana filters by job=, dash0 by service_name= — both interpolate
  # the raw value). If everything were slugged, the queries would stop matching the emitted name.
  check "#99 $g golden still references the RAW var.service_name (queries/titles unslugged)" \
    'grep -q "var.service_name" "'"$SNAP"'"'
done

# --- #109: check_rule_yaml must be a full PrometheusRule doc, not a flat alert body -------------
DASH0_SNAP="tests/snapshots/dash0/main.tf.snap"
PATTERNS="skills/terraform-patterns/SKILL.md"

for rule in error_rate latency; do
  check "#109 dash0 golden's $rule check_rule_yaml is a PrometheusRule doc" \
    'awk "/resource \"dash0_check_rule\" \"'"$rule"'\"/,/^}/" "$DASH0_SNAP" | grep -q "kind: PrometheusRule"'
  check "#109 dash0 golden's $rule check_rule_yaml has exactly one spec.groups entry" \
    '[ "$(awk "/resource \"dash0_check_rule\" \"'"$rule"'\"/,/^}/" "$DASH0_SNAP" | grep -cE "^\s*- name: Alerting")" -eq 1 ]'
  check "#109 dash0 golden's $rule check_rule_yaml has exactly one rule in that group" \
    '[ "$(awk "/resource \"dash0_check_rule\" \"'"$rule"'\"/,/^}/" "$DASH0_SNAP" | grep -cE "^\s*- alert:")" -eq 1 ]'
done
check "#109 dash0 golden uses a hyphen-based slug for metadata.name (DNS-1123, not service_slug)" \
  'grep -q "resource_name_slug" "$DASH0_SNAP"'
check "#109 resource_name_slug is hyphen-separated, not underscore" \
  'grep -A2 "resource_name_slug = " "$DASH0_SNAP" | grep -q '"'"'"-"'"'"''
check "#109 terraform-patterns documents the PrometheusRule envelope requirement" \
  'grep -qF "check_rule_yaml\` must be a full \`PrometheusRule\` document" "$PATTERNS"'

# #103 — dataset default. The golden must default to "default", never "production" (the
# shared `environment` variable's default — the confirmed root cause of the bug: pattern-matching
# dataset onto environment). The authored guidance must say so explicitly, not just happen to
# have the right value in the golden — that's what stops a future regeneration from drifting.
check "#103 dash0 golden's dash0_dataset defaults to \"default\"" \
  'grep -A3 "variable \"dash0_dataset\"" "$DASH0_SNAP" | grep -q '"'"'default     = "default"'"'"''
check "#103 dash0 golden's dash0_dataset default is NOT \"production\"" \
  '! grep -A3 "variable \"dash0_dataset\"" "$DASH0_SNAP" | grep -q '"'"'default     = "production"'"'"''
check "#103 terraform-patterns explicitly warns against defaulting dataset to production" \
  'grep -qi "never default this to \\\\\"production\\\\\"" "$PATTERNS"'

# #104 — folder-path leading slash. Authored as a Key gotcha (the golden's own dashboard_yaml
# does not use this annotation, so the guard lives in prose, not a golden-value check).
check "#104 terraform-patterns documents the folder-path leading-slash requirement" \
  'grep -qF "folder-path\` annotation, if you add one, MUST start with a leading \`/\`" "$PATTERNS"'

# #102 — auth token scope. Golden and guidance must agree (word-for-word, since the golden's
# description is meant to BE the authoritative text, copied verbatim per terraform-gen.md).
check "#102 dash0 golden's dash0_auth_token description mentions management/write scope" \
  'grep -q "management/write API access" "$DASH0_SNAP"'
check "#102 terraform-patterns' dash0_auth_token description matches (golden not drifted)" \
  'grep -c "management/write API access" "$PATTERNS" | grep -qE "^[1-9]"'

echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
