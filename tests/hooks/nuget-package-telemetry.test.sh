#!/usr/bin/env bash
# tests/hooks/nuget-package-telemetry.test.sh
# Locks #215: a Meter/ActivitySource registered by name (AddMeter/AddSource) that isn't defined
# in this repo's own source may live inside a referenced NuGet package. The scanner (which has
# Bash) checks the local NuGet cache; the auditor (which does not have Bash) only ever surfaces
# what the scanner already recorded, never re-attempts the check itself.
set -uo pipefail
cd "$(dirname "$0")/../.."
pass=0; fail=0
check() { if eval "$2"; then echo "PASS: $1"; pass=$((pass+1)); else echo "FAIL: $1"; fail=$((fail+1)); fi; }

SCANNER="agents/repo-context-scanner.md"
AUDITOR="agents/brownfield-auditor.md"

check "scanner defines the AddMeter/AddSource-by-name detection rule" \
  'grep -qF ".NET meters/sources registered BY NAME from a referenced package (#215)" "$SCANNER"'
check "scanner checks the local NuGet cache path convention before attempting anything" \
  'grep -qF "~/.nuget/packages/<id>/" "$SCANNER"'
check "scanner requires grep -a (or strings), not plain grep, against a binary DLL — the exact empirically-confirmed gotcha" \
  'grep -qF "grep -a -o" "$SCANNER" \
   && grep -qiF "plain \`grep\` with no binary override silently" "$SCANNER" \
   && grep -qiF "confirmed empirically" "$SCANNER"'
check "scanner records all three outcomes in derived.notes: confirmed, not-cached, cached-but-absent" \
  'grep -qF "confirmed defined in package" "$SCANNER" \
   && grep -qF "present in the local NuGet cache" "$SCANNER" \
   && grep -qF "not found in package" "$SCANNER"'
check "scanner is explicit this reads literal string constants, not decompilation" \
  'grep -qi "not decompiling anything" "$SCANNER"'

check "auditor states it has no Bash tool and so cannot inspect a DLL itself" \
  'grep -qF "You have no \`Bash\` tool" "$AUDITOR" && grep -qiF "cannot inspect a NuGet-cached DLL yourself" "$AUDITOR"'
check "auditor surfaces the scanner's derived.notes verbatim rather than re-attempting or second-guessing" \
  'grep -qiF "rather than re-attempting or second-guessing it" "$AUDITOR"'
check "auditor treats a confirmed match as a plain fact, not a finding needing a severity/ID" \
  'grep -qiF "is a plain fact worth noting" "$AUDITOR"'
check "auditor says to name the specific attribute/package, not a generic could-not-verify line" \
  "grep -qiF \"don't just say\" \"\$AUDITOR\" && grep -qiF 'some telemetry could not be verified' \"\$AUDITOR\""

echo ""
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
