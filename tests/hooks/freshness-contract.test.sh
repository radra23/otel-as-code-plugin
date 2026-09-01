#!/usr/bin/env bash
# tests/hooks/freshness-contract.test.sh
# Guards the #30 contract: the scanner's `identityInputs` (agents/repo-context-scanner.md) must be
# EXACTLY the set that /otel-init Step 1's freshness regex (commands/otel-init.md) can reproduce.
# When they disagree, the recomputed set never equals the stored set, so the cache is judged stale
# on every command forever — a cache that can never hit. The two were written independently and
# never cross-checked, which is how that shipped; this test cross-checks them.
set -uo pipefail
cd "$(dirname "$0")/../.."
pass=0; fail=0

SCANNER="agents/repo-context-scanner.md"
INIT="commands/otel-init.md"

# The /otel-init Step 1 freshness regex, kept identical to commands/otel-init.md. If the doc's
# regex legitimately changes, update this line too — that update IS the point of check 0.
REGEX='(^|/)(package\.json|pyproject\.toml|requirements\.txt|go\.mod|Cargo\.toml|pom\.xml|build\.gradle(\.kts)?|global\.json|Directory\.Packages\.props|[^/]+\.(csproj|fsproj|sln)|Dockerfile|host\.json|serverless\.yml|CODEOWNERS)$'

# check 0: otel-init.md still carries the regex this test mirrors (drift guard on the mirror).
if grep -qF 'package\.json|pyproject\.toml|requirements\.txt|go\.mod|Cargo\.toml|pom\.xml|build\.gradle' "$INIT"; then
  echo "PASS: /otel-init Step 1 still carries the expected freshness regex"; pass=$((pass+1))
else
  echo "FAIL: /otel-init Step 1 freshness regex changed — update REGEX in this test to match"; fail=$((fail+1))
fi

# check 1: every path in the scanner's documented identityInputs example is reproducible by the regex.
if python3 - "$SCANNER" "$REGEX" <<'PY'
import json, re, sys
doc = open(sys.argv[1]).read()
m = re.search(r'"identityInputs"\s*:\s*(\[[^\]]*\])', doc)
if not m:
    print("no identityInputs example found in scanner doc"); sys.exit(1)
paths = json.loads(m.group(1))
rx = re.compile(sys.argv[2])
bad = [p for p in paths if not rx.search(p)]
if bad:
    print("identityInputs example not reproducible by the Step 1 regex:", bad); sys.exit(1)
print("ok:", paths); sys.exit(0)
PY
then
  echo "PASS: scanner identityInputs example is reproducible by the Step 1 regex"; pass=$((pass+1))
else
  echo "FAIL: scanner identityInputs example has a path the Step 1 regex cannot produce (#30)"; fail=$((fail+1))
fi

# check 2: the scanner no longer defines identityInputs to include bare service root directories,
# the specific broad-prose bug from #30.
if ! grep -q "service root directories themselves" "$SCANNER"; then
  echo "PASS: scanner no longer includes bare service root directories in identityInputs"; pass=$((pass+1))
else
  echo "FAIL: scanner still lists bare service root directories in identityInputs (#30 regression)"; fail=$((fail+1))
fi

echo ""
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
