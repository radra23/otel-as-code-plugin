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
#   #107 — /otel-collector --public wires bearertokenauth into the OTLP receiver (both grpc and
#         http), token from an env var; the default (non-public) config stays auth-free.
#   #124 — two proactive hardening checks, not a live bug: (a) the scanner's deploymentEnvConfigured
#         field must exist and instrumentation-gen/brownfield-auditor must both act on it (elevate
#         an unprovisioned DEPLOYMENT_ENV to a warning / finding, not a buried doc note); (b) a
#         pre-existing Next.js onRequestError export must be checked against frameworkVersion, since
#         the hook doesn't exist before Next.js 15.
#   #120 — /otel-instrument --fix must only mechanically rewrite a CV finding when the OLD->NEW
#         table says it's a safe key rename; a value-shape change (http.target splitting into
#         url.path + url.query; peer.service not being a rename at all) must be refused and
#         reported, never guessed.
#   #136 — the reserved-namespace collision rule must be a two-part test (reserved first segment
#         AND not itself a registered attribute), not a first-segment-only match — otherwise it
#         flags OTel's own registered attributes (user.id, session.id, error.type) as errors.
#   #132 — /otel-business-attrs Step 3 must not re-derive service.name from the manifest; the
#         scanner already resolved it under its ladder (#57) and Step 3 re-deriving it at
#         auto-write confidence silently overwrote the correct observed name.
#   #134/#135 — a Python CLI's instrumentation-gen contract must (a) know a standalone service can
#         be a multi-entry-point CLI tool (cliEntryPoints), not just a single process, and (b)
#         never decorate a Click Group's own callback — Click invokes the group callback and
#         returns from it BEFORE separately invoking the chosen subcommand, so a decorator there
#         produces a zero-duration span and tears down telemetry before the subcommand runs.
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

# --- #107: --public wires bearertokenauth into the OTLP receiver, never by default -------------
COLLECTOR_SKILL="skills/collector-topology/SKILL.md"
COLLECTOR_CMD="commands/otel-collector.md"
PUBLIC_GOLDEN="tests/snapshots/collector/otelcol-agent-public.yaml.snap"
BASE_GOLDEN="tests/snapshots/collector/otelcol-agent.yaml.snap"

# These two replace bare keyword-presence greps (grep -q -- "--public" / grep -q "bearertokenauth")
# that survive deletion of the actual behavioral instructions — caught by a 3-judge critique
# (.claude/reviews/pr-111-critique.md) that mutation-tested the original checks and found all
# three (grpc-only wiring, deleted --public apply block, deleted TLS-required text) still passed
# 37/37. Assert the RULE, not that the topic was mentioned somewhere.
check "#107 collector-topology's own Receiver-auth shape wires BOTH receiver protocols" \
  '[ "$(grep -c "authenticator: bearertokenauth$" "$COLLECTOR_SKILL")" -eq 2 ]'
check "#107 collector-topology sources the receiver token from an env var, never a literal" \
  'grep -q "token: \"\${env:COLLECTOR_AUTH_TOKEN}\"" "$COLLECTOR_SKILL"'
check "#107 /otel-collector Step 4 wires --public into BOTH protocols by name" \
  'grep -q "grpc.auth.authenticator" "$COLLECTOR_CMD" && grep -q "http.auth.authenticator" "$COLLECTOR_CMD"'
check "#107 TLS-in-front is stated as REQUIRED, not a passing mention" \
  'grep -qF "REQUIRED: terminate TLS in front of this collector" "$COLLECTOR_CMD"'

check "#107 --public golden wires auth into BOTH grpc and http receiver protocols" \
  '[ "$(grep -c "authenticator: bearertokenauth" "$PUBLIC_GOLDEN")" -eq 2 ]'
check "#107 --public golden sources the token from an env var, never a literal" \
  'grep -q "token: \"\${env:COLLECTOR_AUTH_TOKEN}\"" "$PUBLIC_GOLDEN"'
check "#107 --public golden declares the extension in service.extensions" \
  'grep -q "extensions: \[bearertokenauth\]" "$PUBLIC_GOLDEN"'
# The DEFAULT (non---public) golden must stay auth-free — --public must never become the
# default behavior by a later edit accidentally merging the two goldens. -f guards against the
# check passing vacuously if the file is ever renamed away (grep exits 2 on a missing file, which
# `!` would otherwise silently turn into a pass).
check "#107 the default (non-public) golden has NO auth block (opt-in stays opt-in)" \
  '[ -f "$BASE_GOLDEN" ] && ! grep -q "authenticator:" "$BASE_GOLDEN"'

# --- #107 fast-follow: regen without --public must not silently strip existing auth -------------
# All 3 judges in the critique independently flagged this as the single highest-priority gap:
# `--force` alone (no --public) on a config that already has auth used to regenerate it away —
# exactly the vulnerability #107 reported, reintroduced by a forgotten flag.
check "#107 --force is gated when the existing config already has auth" \
  'grep -qF "was NOT passed this run" "$COLLECTOR_CMD"'
check "#107 --confirm-remove-auth is the only way to intentionally downgrade" \
  'grep -q -- "--confirm-remove-auth" "$COLLECTOR_CMD"'

# --- #107 fast-follow: discoverability — the default (non-public) run says auth exists ----------
check "#107 default (non-public) output points at --public (discoverability)" \
  'grep -qF "this receiver has no auth" "$COLLECTOR_CMD"'
check "#107 --public documented in the README flag table" \
  'grep -qF -- "--public" README.md'

# --- #107 fast-follow: gateway senders are agent Collectors, not apps ---------------------------
# OTEL_EXPORTER_OTLP_HEADERS is an SDK/app env var; an otelcol otlp exporter does not read it.
# Gateway-mode --public output must NOT tell the user to set it there — it needs client-side
# bearertokenauth on each agent's own exporter instead.
check "#107 gateway --public output uses client-side bearertokenauth, not an app env var" \
  'grep -qF "bearertokenauth/client" "$COLLECTOR_CMD"'
check "#107 collector-topology explicitly says agent vs gateway senders differ" \
  'grep -qF "sender-side" "$COLLECTOR_SKILL"'

# --- #107 fast-follow: /otel-instrument knows to add the auth header when the collector needs it -
check "#107 /otel-instrument checks for a --public collector and adds the auth header" \
  'grep -qF "authenticator: bearertokenauth" commands/otel-instrument.md \
     && grep -qF "OTEL_EXPORTER_OTLP_HEADERS" commands/otel-instrument.md'

# --- #107 Medium fast-follow: insecure:false is authored guidance, not a golden-only value ------
check "#107 collector-topology authors the insecure:false-under-public rule" \
  'grep -qF "Also set the exporter" "$COLLECTOR_SKILL"'
check "#107 /otel-collector Step 4 applies the insecure:false rule" \
  'grep -qF "exporters.otlp.tls.insecure: false" "$COLLECTOR_CMD"'
check "#107 --public golden actually sets insecure: false (golden matches guidance)" \
  'grep -qF "insecure: false" "$PUBLIC_GOLDEN"'

# --- #107 Medium fast-follow: the auth-wiring guard (otelcol validate doesn't catch dangling
# authenticator refs or an extension left out of service.extensions) still exists and is called --
check "#107 collector-validate.sh still defines and calls check_auth_wiring" \
  'grep -qF "check_auth_wiring() {" tests/collector-validate.sh \
     && grep -qF "check_auth_wiring \"\$PUBLIC_CONFIG\"" tests/collector-validate.sh'

# --- #107 Low fast-follow: OTEL_EXPORTER_OTLP_HEADERS must be percent-encoded (Bearer%20), not a
# literal space -- the OTel Python SDK rejects an unencoded space with UNAUTHENTICATED on every
# export (verified against the OTel spec + a documented real-world break, not asserted from memory).
# Scoped to the ENV-VAR print form specifically (OTEL_EXPORTER_OTLP_HEADERS=...) -- a line
# describing the resulting WIRE-level HTTP header ("Authorization: Bearer <token>", with a colon)
# is a different, correctly-space-separated thing and must not be flagged.
for f in "$COLLECTOR_CMD" commands/otel-instrument.md "$COLLECTOR_SKILL" "$PUBLIC_GOLDEN"; do
  check "#107 $f's OTEL_EXPORTER_OTLP_HEADERS value is percent-encoded, not a literal space" \
    '! grep -qE "OTEL_EXPORTER_OTLP_HEADERS ?= ?Authorization=Bearer[^%]" "'"$f"'"'
done

# --- #107 Low fast-follow: --dry-run + --public still prints the REQUIRED TLS advisory ----------
check "#107 --dry-run flag description addresses the --public interaction" \
  'grep -qF "Combined with \`--public\`, still" "$COLLECTOR_CMD"'

# --- #124a: DEPLOYMENT_ENV provisioning is checked, not just documented -------------------------
GEN="agents/instrumentation-gen.md"
AUDITOR="agents/brownfield-auditor.md"

check "#124a scanner defines deploymentEnvConfigured (mirrors endpointConfigured)" \
  'grep -q "deploymentEnvConfigured" "$SCANNER"'
check "#124a instrumentation-gen elevates an unprovisioned DEPLOYMENT_ENV to a warning" \
  'grep -q "deploymentEnvConfigured" "$GEN" && grep -qF "elevate it to a \`⚠\`-prefixed headline warning" "$GEN"'
check "#124a brownfield-auditor's telemetry-configuration dimension checks deploymentEnvConfigured" \
  'grep -q "deploymentEnvConfigured" "$AUDITOR"'

# --- #124b: a pre-existing onRequestError export is checked against the Next.js version ---------
NEXTFIX="fixtures/nextjs-onrequesterror-old"

check "#124b scanner defines frameworkVersion (so a version-gated hook can be judged)" \
  'grep -q "frameworkVersion" "$SCANNER"'
check "#124b instrumentation-gen's Next.js section names onRequestError's version gate (15)" \
  'grep -q "onRequestError" "$GEN" && grep -qF "only exists from Next.js 15 onward" "$GEN"'
check "#124b brownfield-auditor's wiring dimension names the same onRequestError gate" \
  'grep -q "onRequestError" "$AUDITOR"'
check "#124b fixture pins next below 15 (repro intact)" \
  'grep -qE "\"next\": \"[\^~]?14\." "$NEXTFIX/package.json"'
check "#124b fixture's instrumentation.ts actually exports onRequestError (the disqualifying fact)" \
  'grep -q "onRequestError" "$NEXTFIX/instrumentation.ts"'

# --- #120: --fix only mechanically rewrites a CV finding when it's a safe key rename ------------
SEMCONV="skills/semconv-discipline/SKILL.md"
INSTRUMENT_CMD="commands/otel-instrument.md"

check "#120 semconv-discipline's OLD->NEW tables carry a Fix classification column" \
  '[ "$(grep -c "| Fix |" "$SEMCONV")" -ge 2 ]'
check "#120 semconv-discipline marks a same-value rename mechanical (http.method)" \
  'grep -qF "| \`http.method\`       | \`http.request.method\`     | mechanical |" "$SEMCONV"'
check "#120 semconv-discipline marks the value-split case manual (http.target)" \
  'grep -qF "| \`http.target\`       | \`url.path\` + \`url.query\`  | manual" "$SEMCONV"'
check "#120 semconv-discipline marks peer.service manual (not a rename at all)" \
  'grep "peer.service" "$SEMCONV" | grep -q "manual — not a rename"'
check "#120 instrumentation-gen's fixList handling only applies mechanical CV entries" \
  'grep -qF "only gets applied if it says \`mechanical\`" agents/instrumentation-gen.md'
check "#120 instrumentation-gen refuses (not guesses) a manual CV entry" \
  'grep -qF "guess a value transformation" agents/instrumentation-gen.md'
check "#120 instrumentation-gen treats an unclassified CV entry as manual (safe default)" \
  'grep -qF "treat it as \`manual\` — refusing is the safe default" agents/instrumentation-gen.md'
check "#120 brownfield-auditor carries the Fix classification into CV findings" \
  'grep -qF "carry it into the" agents/brownfield-auditor.md'
check "#120 brownfield-auditor's worked example shows a manual CV finding, not just mechanical" \
  'grep -qF "manual — value must be parsed apart, not renamed" agents/brownfield-auditor.md'
check "#120 /otel-instrument --fix flag docs state the mechanical/manual distinction" \
  'grep -qF "reported back as skipped" "$INSTRUMENT_CMD"'
check "#120 /otel-instrument documents --fix + --dry-run as the review-before-apply UX" \
  'grep -qF "Also" "$INSTRUMENT_CMD" && grep -qF "pairs with \`--fix\`" "$INSTRUMENT_CMD"'

# --- #136: reserved-namespace collision is a two-part test, not first-segment-only -------------
check "#136 rule is stated as a two-part test (reserved segment AND not registered)" \
  'grep -qF "This is a two-part test" "$SEMCONV"'
check "#136 registered examples are named CORRECT despite a reserved first segment" \
  'grep -qF "using them for their" "$SEMCONV" && grep -qF "registered meaning is CORRECT, not a collision" "$SEMCONV"'
check "#136 user.id, session.id (from the cardinality canonical set) are named registered" \
  'grep -qF "\`user.id\`, \`user.name\`, \`user.email\`," "$SEMCONV" && grep -qF "\`session.id\`, \`error.type\`" "$SEMCONV"'
check "#136 error.type is named registered (a plugin-generated attribute, not just a doc example)" \
  'grep -qF "\`session.id\`, \`error.type\`, \`code.function.name\` are registered" "$SEMCONV"'
check "#136 renaming a registered attribute out of its namespace is stated as wrong, not just unneeded" \
  'grep -qF "required, not merely permitted" "$SEMCONV"'
check "#136 the collision examples (deployment.name, message.notificationId) still verify BOTH conditions" \
  'grep -qF "deployment.name\` — \`deployment.\` is reserved and" "$SEMCONV" \
     && grep -qF "message.notificationId\` — \`message.\` is the RPC registry" "$SEMCONV"'

# --- #132: /otel-business-attrs must not re-derive service.name from the manifest ---------------
BIZATTRS_CMD="commands/otel-business-attrs.md"
BIZATTRS_SKILL="skills/business-attr-ux/SKILL.md"

check "#132 Step 3 explicitly says service.name is not re-derived here" \
  'grep -qF "is already resolved — do not re-derive it here" "$BIZATTRS_CMD"'
check "#132 Step 3 points at the scanner's ladder, not a manifest, for service.name" \
  'grep -qF "The scanner resolved it under" "$BIZATTRS_CMD"'
check "#132 Step 3's Tier 1 no longer lists service.name as a package.json/pyproject candidate" \
  '! grep -qE "\`service\.name\`.*from.*(package\.json|pyproject\.toml)" "$BIZATTRS_CMD"'
check "#132 Step 3's service.version manifest list covers all six languages, including a stated go gap" \
  'grep -q "dotnet.*csproj" "$BIZATTRS_CMD" && grep -q "ruby.*gemspec" "$BIZATTRS_CMD" \
     && grep -q "java.*pom.xml" "$BIZATTRS_CMD" && grep -qF "no manifest source" "$BIZATTRS_CMD"'
check "#132 business-attr-ux skill matches the command (no longer offers service.name examples)" \
  'grep -qF "is NOT derived here at all" "$BIZATTRS_SKILL"'
check "#132 skill's confirmation-table example shows service.name as scanner-carried, not a fresh derivation" \
  'grep -qF "already resolved by the scanner" "$BIZATTRS_SKILL"'

# --- #134/#135: standalone multi-entry-point Python CLI, and Click Group vs plain command --------
check "#134/#135 scanner defines cliEntryPoints as the standalone-CLI signal" \
  'grep -qF "cliEntryPoints" "$SCANNER"'
check "#134/#135 instrumentation-gen has a dedicated CLI section keyed on cliEntryPoints" \
  'grep -qF "Standalone multi-entry-point CLI" "$GEN" && grep -qF "service.cliEntryPoints\` (from the context JSON) is non-empty" "$GEN"'
check "#134/#135 the contract explicitly forbids decorating a Click Group's own callback" \
  'grep -qF "do **not** wrap the group'"'"'s own callback function" "$GEN"'
check "#134/#135 the reason given is Click's invoke() sequencing (zero-duration span), not just an assertion" \
  'grep -qF "MultiCommand.invoke()" "$GEN" && grep -qF "start_time == end_time" "$GEN"'
check "#134/#135 subcommands are wrapped individually with a <entry> <subcommand> span name" \
  'grep -qF "wrap **each subcommand" "$GEN" && grep -qF "pii-scanner scan" "$GEN"'
check "#134/#135 flush is per-invocation (finally), not only atexit/SIGTERM" \
  'grep -qF "Flush before exit, every invocation" "$GEN" && grep -qF "not only on \`SIGTERM\`" "$GEN"'
check "#134/#135 worked example decorates the subcommand, NOT the group callback (structural check)" \
  '! grep -B1 "^def cli():" "$GEN" | grep -q "@traced_command" \
     && grep -B1 "^def scan():" "$GEN" | grep -q "@traced_command"'

# --- #133: businessAttrs needs a histogram kind, rendered as quantiles, not an average -----------
BIZ_SKILL="skills/business-attr-ux/SKILL.md"
TFGEN="agents/terraform-gen.md"
TFPATTERNS="skills/terraform-patterns/SKILL.md"

check "#133 business-attr-ux's kind enum includes histogram" \
  'grep -qF "counter|gauge|dimension|histogram" "$BIZ_SKILL"'
check "#133 business-attr-ux's histogram heuristic names the shape suffixes" \
  'grep -qF "_duration\`/\`_latency\`/\`_size\`/\`_bytes\`" "$BIZ_SKILL"'
check "#133 business-attr-ux adds a nullable unit field for axis labeling" \
  'grep -qF "\`unit\` (optional, best-effort)" "$BIZ_SKILL"'
check "#133 otel-business-attrs Step 6 writes histogram + unit into businessAttrs entries" \
  'grep -qF "\`\"dimension\"\`, or" commands/otel-business-attrs.md && grep -qF "\"unit\"" commands/otel-business-attrs.md'
check "#133 terraform-gen renders histogram as quantiles (p50/p95/p99), not an average" \
  'grep -qF "kind: \"histogram\"" "$TFGEN" && grep -qF "p50/p95/p99" "$TFGEN"'
check "#133 terraform-gen's kind-skip rule is kind-agnostic (future kind never falls through to a default)" \
  'grep -qF "not one of the four values above" "$TFGEN" && grep -qF "never falls through to a default rendering" "$TFGEN"'
check "#133 terraform-patterns defines a histogram query for all four backends" \
  '[ "$(grep -c "kind: histogram" "$TFPATTERNS")" -eq 4 ]'
check "#133 terraform-patterns' Grafana histogram query uses histogram_quantile, never avg(_sum/_count)" \
  'grep -A3 "kind: histogram.*OTLP.Prometheus emits a" "$TFPATTERNS" | grep -q "histogram_quantile(0.50"'
check "#133 terraform-patterns New Relic histogram query uses NRQL multi-value percentile() in one call" \
  'grep -qF "percentile(\`<name>\`, 50, 95, 99)" "$TFPATTERNS"'

echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
