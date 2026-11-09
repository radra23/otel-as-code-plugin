#!/usr/bin/env bash
# tests/hooks/vendor-mcp-offer.test.sh
# Locks the vendor-MCP enrichment pattern prototyped across three commands this session:
# /otel-backend, /otel-evaluate, /otel-collector each got an optional "offer live verification
# via a connected vendor MCP" step, never required, never calling a tool, detection only.
#
# Each command detects "which vendor" a genuinely different way (the explicit --vendor arg for
# otel-backend; an existing infra/observability/<vendor>/ directory for the other two, since
# neither has a vendor flag and otel-collector's exporter is deliberately vendor-agnostic), and
# each gates on a different signal for "is there actually something to verify" (otel-backend:
# none, the vendor is given directly; otel-evaluate: endpointConfigured:true on an audited
# service; otel-collector: the exporter actually carrying headers/auth). This test locks that
# each command's gate is real (references a field/phrase that genuinely exists in that same
# file or in the scanner's schema, not an invented one) and that the three commands' detection
# mechanism and "never call a tool" rule are stated consistently, not independently reinvented
# with a silent gap (the exact kind of drift this test exists to catch early -- found and fixed
# one real instance of this while writing it: otel-evaluate and otel-collector's Step 7 omitted
# HOW to match an MCP to a vendor, which only otel-backend's Step 7 spelled out).
set -uo pipefail
cd "$(dirname "$0")/../.."
pass=0; fail=0
check() { if eval "$2"; then echo "PASS: $1"; pass=$((pass+1)); else echo "FAIL: $1"; fail=$((fail+1)); fi; }

BACKEND="commands/otel-backend.md"
EVAL="commands/otel-evaluate.md"
COLLECTOR="commands/otel-collector.md"
SCANNER="agents/repo-context-scanner.md"

# --- all three carry the same step, same title ---
for f in "$BACKEND" "$EVAL" "$COLLECTOR"; do
  check "$f has the vendor-MCP Step 7 heading" \
    "grep -qF '## Step 7: Offer optional live verification via a connected vendor MCP' '$f'"
done

# --- all three state the enrichment-only rule, in their own words ---
check "otel-backend states the Terraform is already complete on its own" \
  'grep -qF "the Terraform above is already complete and correct on its" "$BACKEND"'
check "otel-evaluate states enrichment only, never required" \
  'grep -qF "**Enrichment only, never required.**" "$EVAL"'
check "otel-collector states enrichment only, never required" \
  'grep -qF "enrichment only, never" "$COLLECTOR" && grep -qF "required, and never attempted" "$COLLECTOR"'

# --- all three state the detection mechanism, either directly or by cross-reference ---
check "otel-backend spells out the detection mechanism directly (search tool names for the vendor)" \
  'grep -qF "search available" "$BACKEND" \
   && grep -qF "tools for a name containing the vendor" "$BACKEND"'
check "otel-evaluate cross-references otel-backends detection mechanism rather than silently omitting it" \
  'grep -qF "Step 7 does (search available tools for a name containing the vendor" "$EVAL"'
check "otel-collector cross-references otel-backends detection mechanism rather than silently omitting it" \
  'grep -qF "Step 7 does (search available tools for a name containing the vendor" "$COLLECTOR"'

# --- all three explicitly forbid calling a tool in this step, in their own words ---
check "otel-backend forbids calling any MCP tool in this step" \
  'grep -qiF "do not call any mcp tool in this step" "$BACKEND"'
check "otel-evaluate forbids calling any MCP tool in this step" \
  'grep -qF "**Never call any MCP tool in this step.**" "$EVAL"'
check "otel-collector forbids calling any MCP tool in this step" \
  'grep -qiF "never attempted in this step" "$COLLECTOR"'

# Teeth: scan each command's ENTIRE Step 7 section specifically (not the whole file -- an MCP
# tool call elsewhere, e.g. in a different command's unrelated step, must not fail this) for an
# actual tool-invocation-shaped line (mcp__<server>__<tool> syntax). None of the three may
# contain one -- the whole point of "detection only" is that this step never issues a real call.
extract_step7() {
  awk '/^## Step 7: Offer optional live verification/{f=1} f{print} f&&/^## Step [0-9]+:/&&!/^## Step 7:/{exit}' "$1"
}
for f in "$BACKEND" "$EVAL" "$COLLECTOR"; do
  SECTION=$(extract_step7 "$f")
  if echo "$SECTION" | grep -qE 'mcp__[a-zA-Z0-9_]+__[a-zA-Z0-9_]+\('; then
    echo "FAIL: teeth: $f's Step 7 contains an actual tool-invocation-shaped call"; fail=$((fail+1))
  else
    echo "PASS: teeth: $f's Step 7 contains no tool-invocation-shaped call"; pass=$((pass+1))
  fi
done

# --- otel-backend: vendor is given directly, so Step 7 must NOT gate on an infra/ directory
#     existing -- that directory is this command's own OUTPUT, requiring it first would be
#     circular (the vendor is already known from --vendor before Step 7 ever runs) ---
BACKEND_STEP7=$(extract_step7 "$BACKEND")
check "otel-backend's Step 7 does not gate on infra/observability/ existing (vendor is already explicit)" \
  '! echo "$BACKEND_STEP7" | grep -qF "infra/observability"'

# --- otel-evaluate and otel-collector: both detect the vendor the same way, from the same
#     source list, using the exact same convention string ---
check "otel-evaluate detects the vendor from an existing infra/observability/<vendor>/ directory" \
  'grep -qF "infra/observability/<vendor>/" "$EVAL" && grep -qF "backends.txt" "$EVAL"'
check "otel-collector detects the vendor the SAME way, not a different heuristic" \
  'grep -qF "infra/observability/<vendor>/" "$COLLECTOR" && grep -qF "backends.txt" "$COLLECTOR"'
check "otel-collector explicitly refuses to guess the vendor from the exporter's endpoint hostname" \
  'grep -qiF "inventing one from the" "$COLLECTOR" \
   && grep -qiF "unverified vendor-to-hostname mapping" "$COLLECTOR"'

# --- otel-evaluate's gate (endpointConfigured) is a real scanner field, not invented ---
check "teeth: endpointConfigured referenced by otel-evaluate's gate is a real scanner-defined field" \
  'grep -qF "endpointConfigured" "$EVAL" && grep -qF "\`endpointConfigured\`" "$SCANNER"'
check "otel-evaluate skips the offer when no audited service has endpointConfigured:true" \
  'grep -qF "endpointConfigured\` is \`false\` or \`null\`, skip this step too" "$EVAL"'

# --- otel-collector's gate (exporter has no headers/auth) references a real phrase from the
#     SAME file's own Step 6, not a dangling or invented condition ---
check "teeth: otel-collector's gate references the exact 'no credentials' phrase Step 6 prints" \
  'grep -qF "exporter sends no credentials" "$COLLECTOR" \
   && [ "$(grep -c "exporter sends no credentials" "$COLLECTOR")" -ge 2 ]'
check "otel-collector skips the offer when the exporter carries no credentials" \
  'grep -qF "If Step 6 printed the" "$COLLECTOR" && grep -qF "skip this step too" "$COLLECTOR"'

# --- otel-backend names the concrete resource per vendor, never a generic word ---
check "otel-backend names a concrete resource per vendor (not a generic placeholder)" \
  'grep -qF "Grafana: \"the dashboard" "$BACKEND" && grep -qF "Dash0: \"the" "$BACKEND"'

echo
echo "vendor-mcp-offer: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
