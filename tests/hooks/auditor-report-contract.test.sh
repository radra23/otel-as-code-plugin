#!/usr/bin/env bash
# tests/hooks/auditor-report-contract.test.sh
# Locks #226, six gaps in brownfield-auditor's output contract:
#   1. Finding IDs were "a short hash" with no actual algorithm an auditor (no Bash, no code
#      execution) can compute deterministically -- replaced with a MECHANICAL substring-copying
#      construction that needs no arithmetic.
#   2. The severity scale (CRITICAL/HIGH/MEDIUM/MINOR) never said how it maps onto
#      semconv-discipline's own error/warning/acceptable cardinality tiers -- added an explicit
#      mapping (error->HIGH, warning->MEDIUM).
#   3. The report template lacked fix kind (code/config/infra), latent-vs-live,
#      "unverifiable from source", and "deliberate decision confirmed" as structured annotations.
#   4. A zero-match search read as a clean result with no way to tell a broken search from a
#      genuinely clean one -- added a positive-control requirement.
#   5. A scanner rescan silently dropped auditor-sourced derived.* entries (nothing left to
#      re-verify) and a `refuted` CV finding was hard-deleted (no retained history) -- scanner now
#      unions auditor-sourced/refuted entries forward across a rescan; otel-evaluate now sets
#      refuted:true/refutedAt on a CV entry instead of deleting it.
#   6. Nothing stamped the auditor's own `Scanned:` line from a real clock -- otel-evaluate now
#      passes a real scanTime, and the auditor is told to use it verbatim, never invent a date.
set -uo pipefail
cd "$(dirname "$0")/../.."
pass=0; fail=0
check() { if eval "$2"; then echo "PASS: $1"; pass=$((pass+1)); else echo "FAIL: $1"; fail=$((fail+1)); fi; }

AUDITOR="agents/brownfield-auditor.md"
EVAL="commands/otel-evaluate.md"
SCANNER="agents/repo-context-scanner.md"
INSTR="commands/otel-instrument.md"

# --- item 1: deterministic, mechanical (non-hash) stable IDs ---
check "auditor explains it has no tool to compute a real hash, so the ID is mechanical substring-copying" \
  'grep -qF "you have no tool to compute" "$AUDITOR" \
   && grep -qF "pure substring-copying" "$AUDITOR"'
check "auditor's ID construction is a numbered, reproducible 3-step procedure using FULL strings (no truncation)" \
  'grep -qF "Take the finding'"'"'s basename: the file'"'"'s basename with its last extension removed" "$AUDITOR" \
   && grep -qF "Append the line number if the finding is anchored to one, else \`0\`" "$AUDITOR" \
   && grep -qF "the finding'"'"'s distinguishing keyword, in full" "$AUDITOR"'
check "the no-truncation choice is explained as a deliberate collision-avoidance decision" \
  'grep -qiF "never truncated" "$AUDITOR" && grep -qiF "collisions" "$AUDITOR" \
   && grep -qF "http.method\`/\`http.mime\`" "$AUDITOR"'
check "worked example no longer uses sequence-looking IDs (SC-1/SC-2/CV-1..4) that contradict the rule" \
  '! grep -qF "[SC-1] Metrics" "$AUDITOR" && ! grep -qF "[CV-1] tracing.js" "$AUDITOR" \
   && ! grep -qF "[CV-2] tracing.js" "$AUDITOR" && ! grep -qF "[CV-4] tracing.js" "$AUDITOR"'
check "worked example no longer uses the old truncated IDs either" \
  '! grep -qF "[CV-tra12-serv]" "$AUDITOR" && ! grep -qF "[CR-dtl103-user]" "$AUDITOR"'
check "worked example uses the full (untruncated) mechanical ID for the tracing.js:12 service.name finding" \
  'grep -qF "[CV-tracing12-servicename] tracing.js:12" "$AUDITOR"'
check "SC (signal coverage) findings use the signal-name exception, not the file+line formula" \
  'grep -qF "SC-metrics\`, \`SC-logs\`" "$AUDITOR" \
   && grep -qF "[SC-metrics] Metrics" "$AUDITOR"'
check "a third exception covers other file-less findings (MB/CF with a distinguishing name but no file)" \
  'grep -qiF "No file at all, but one clear distinguishing name exists" "$AUDITOR" \
   && grep -qF "CF-otelsemconvstabilityoptin" "$AUDITOR"'
check "EX findings use the parent directory name as the keyword, consistently across both worked examples" \
  'grep -qiF "use the PARENT DIRECTORY name as the keyword" "$AUDITOR" \
   && grep -qF "EX-overview0-dashboards" "$AUDITOR" && grep -qF "EX-api0-alerts" "$AUDITOR"'
check "otel-instrument's --fix example IDs match the new untruncated mechanical scheme" \
  'grep -qF "CV-tracing12-servicename,SH-tracing0-simplespanprocessor" "$INSTR"'

# Teeth: extract the Semconv Violations worked example's file/line/attribute AND its shown ID
# directly from the doc (not hardcoded test literals), independently recompute the ID per the
# stated procedure, and confirm they match -- this is tied to the actual file under test, so it
# would catch the worked example and the stated ID drifting apart from each other, not just
# re-assert a fixed assumption about what the doc currently says.
check "teeth: the stated mechanical procedure, applied to values extracted from the doc itself, reproduces the doc's own worked ID" \
  'python3 -c "
import re
text = open(\"$AUDITOR\").read()
# Extract the worked Semconv Violations example line for the service.name finding.
m = re.search(r\"\[CV-([a-z0-9-]+)\] (\S+):(\d+) [^\n]*?(service\.name) set as span attribute\", text)
assert m, \"could not find the tracing.js:12 service.name worked example in the doc\"
shown_id, file_part, line_part, attr = m.group(1), m.group(2), m.group(3), m.group(4)
basename = re.sub(r\"[^a-z0-9]\", \"\", file_part.rsplit(\".\", 1)[0].lower())
keyword = re.sub(r\"[^a-z0-9]\", \"\", attr.lower())
computed = f\"{basename}{line_part}-{keyword}\"
assert computed == shown_id, f\"computed {computed!r} != doc'"'"'s own shown id {shown_id!r}\"
print(\"ok\")
"'

# --- item 2: cardinality tier -> severity mapping ---
check "auditor maps semconv-discipline error/warning cardinality tiers onto HIGH/MEDIUM" \
  'grep -qF "Cardinality tier → severity mapping (#226)" "$AUDITOR" \
   && grep -qF "metric dimension) → **HIGH**" "$AUDITOR" \
   && grep -qF "warning\` (span attribute) → **MEDIUM**" "$AUDITOR"'

# --- item 3: richer report fields (annotations) ---
check "auditor defines fix: code/config/infra, latent/live, unverifiable, deliberate-decision annotations" \
  'grep -qF "**\`fix: code\` / \`fix: config\` / \`fix: infra\`**" "$AUDITOR" \
   && grep -qF "**\`latent\` / \`live\`**" "$AUDITOR" \
   && grep -qF "**\`unverifiable from source\`**" "$AUDITOR" \
   && grep -qF "**\`deliberate decision confirmed\`**" "$AUDITOR"'
check "worked example actually uses the new annotations, not just defines them" \
  'grep -qF "fix: code, live" "$AUDITOR" && grep -qF "fix: config" "$AUDITOR" \
   && grep -qF "unverifiable from source" "$AUDITOR"'
check "otel-instrument --fix explicitly skips fix: config / fix: infra findings" \
  'grep -qF "reported back as skipped too, for the same reason" "$INSTR"'

# --- item 4: positive-control requirement for zero-match searches ---
check "auditor requires a positive control before trusting a clean (zero-match) search result" \
  'grep -qF "A zero-match search needs a positive control before you trust it (#226)" "$AUDITOR" \
   && grep -qiF "not independently confirmed" "$AUDITOR"'

# --- item 5: cache retains auditor-sourced / refuted entries across a rescan ---
check "scanner unions auditor-sourced derived entries forward across a rescan instead of replacing" \
  'grep -qF "Carry forward \`\"source\": \"auditor\"\` entries across a rescan" "$SCANNER" \
   && grep -qiF "union, never replace" "$SCANNER"'
check "scanner also carries a refuted:true entry forward the same way" \
  'grep -qF "carrying \`\"refuted\": true\`" "$SCANNER"'
check "otel-evaluate sets refuted:true/refutedAt on a CV entry instead of deleting it" \
  'grep -qF "set \`\"refuted\": true\` and" "$EVAL" \
   && grep -qF "do NOT delete it (#226)" "$EVAL"'
check "otel-evaluate still removes a refuted CR entry (string-list shape has no per-entry history slot)" \
  'grep -qF "refuted\` on a **\`CR\`**" "$EVAL" && grep -qiF "remove the key from the list" "$EVAL"'
check "auditor knows a refuted:true entry it is handed is retained history, not something to re-litigate" \
  'grep -qF "is a claim a PRIOR audit already disproved" "$AUDITOR"'

# --- item 6: real scanTime, never an invented date ---
check "otel-evaluate passes a real scanTime to the auditor before dispatch" \
  'grep -qF "\`scanTime\`: run \`date -u +%Y-%m-%dT%H:%M:%SZ\` right before this dispatch" "$EVAL"'
check "auditor stamps Scanned: from scanTime verbatim, never an invented date" \
  'grep -qF "Stamp the report'"'"'s \`Scanned:\` line with this value" "$AUDITOR" \
   && grep -qF "never a remembered or invented date" "$AUDITOR"'
check "auditor says what to print when scanTime was not provided, rather than guessing one" \
  'grep -qF "not provided — command did not pass scanTime" "$AUDITOR"'

echo
echo "auditor-report-contract: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
