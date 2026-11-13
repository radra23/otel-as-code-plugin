#!/usr/bin/env bash
# tests/hooks/freshness-contract.test.sh
# Guards the #30 contract: the scanner's `identityInputs` (agents/repo-context-scanner.md) must be
# EXACTLY the set that /otel-init Step 1's freshness regex (commands/otel-init.md) can reproduce.
# When they disagree, the recomputed set never equals the stored set, so the cache is judged stale
# on every command forever — a cache that can never hit. The two were written independently and
# never cross-checked, which is how that shipped; this test cross-checks them. It also guards #150:
# a service with no identity input to fingerprint (a config-only repo) must always read as stale.
# And the scanner's prose basename list must name the same files as the regex (check 5).
set -uo pipefail
cd "$(dirname "$0")/../.."
pass=0; fail=0

SCANNER="agents/repo-context-scanner.md"
INIT="commands/otel-init.md"

# The /otel-init Step 1 freshness regex, kept identical to commands/otel-init.md. If the doc's
# regex legitimately changes, update this line too — that update IS the point of check 0.
REGEX='(^|/)(package\.json|pnpm-workspace\.yaml|pyproject\.toml|requirements\.txt|setup\.py|go\.mod|go\.work|Cargo\.toml|Gemfile|composer\.json|pom\.xml|build\.gradle(\.kts)?|settings\.gradle(\.kts)?|global\.json|Directory\.Packages\.props|[^/]+\.(csproj|fsproj|sln)|([^/]+\.)?Dockerfile(\.[^/]+)?|host\.json|serverless\.yml|CODEOWNERS)$'

# check 0: otel-init.md carries EXACTLY the regex this test mirrors. This compared only a
# prefix before, so appending a new alternative to the doc — the way every new manifest type
# arrives — slipped past silently while the mirror went stale. Compare the whole expression.
if grep -qF "$REGEX" "$INIT"; then
  echo "PASS: /otel-init Step 1 carries exactly the freshness regex this test mirrors"; pass=$((pass+1))
else
  echo "FAIL: /otel-init Step 1 freshness regex differs from REGEX in this test — update the mirror"; fail=$((fail+1))
  echo "  test mirror: $REGEX"
  echo "  in the doc : $(grep -oE "\(\^\|/\)\([^']*\)\\\$" "$INIT" | head -1)"
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

# check 3 (#150): an in-scope service no identity input covers must make the cache STALE. Without
# this rule a repo with zero identity inputs fingerprints the empty set, so both sides are `[]` and
# the cache reads as current forever, whatever happens to its deployment config.
if grep -q "is \*\*uncovered\*\* when no \`identityInputs\` path other than" "$INIT" \
   && grep -q "or \`identityInputs\` is empty, the cache is STALE" "$INIT"; then
  echo "PASS: /otel-init Step 1 treats uncovered services / empty identityInputs as stale (#150)"; pass=$((pass+1))
else
  echo "FAIL: /otel-init Step 1 lost the uncovered-service / empty-identityInputs stale rule (#150)"; fail=$((fail+1))
fi
if grep -q "An empty list is valid" "$SCANNER" && grep -q "always stale" "$SCANNER"; then
  echo "PASS: scanner documents empty identityInputs as valid and always-stale (#150)"; pass=$((pass+1))
else
  echo "FAIL: scanner no longer documents the empty-identityInputs contract (#150)"; fail=$((fail+1))
fi

# check 4 (#150): the keycloak-deployment fixture is the repro, a deployment-only service that the
# Step 1 regex can't match at all. If someone adds a manifest to it, the fixture stops exercising
# the empty-set case, and this check says so.
KC_DIR="fixtures/keycloak-deployment"
kc_matches=$(cd "$KC_DIR" && find . -type f | sed 's|^\./||' | grep -E "$REGEX" || true)
if [ -d "$KC_DIR" ] && [ -z "$kc_matches" ]; then
  echo "PASS: $KC_DIR has no identity inputs, so it exercises the empty-set case (#150)"; pass=$((pass+1))
else
  echo "FAIL: $KC_DIR is missing or now has identity inputs ($kc_matches) — it no longer reproduces #150"; fail=$((fail+1))
fi

# check 5: the scanner's prose list of identity basenames and the Step 1 regex name the same
# files, in both directions. Check 1 only covers the JSON example, so the prose drifted:
# pnpm-workspace.yaml, go.work and settings.gradle(.kts) were in the regex and the example but
# missing from the list the scanner is told to follow, so a scanner obeying the prose stored
# fewer paths than Step 1 recomputes and the cache read as stale on every run in those repos.
if python3 - "$SCANNER" "$REGEX" <<'PY'
import re, sys
doc = open(sys.argv[1]).read()
m = re.search(r'basename is one of (.*?)Nothing else', doc, re.S)
if not m:
    print("no 'basename is one of ... Nothing else' list found in scanner doc"); sys.exit(1)
# `*.csproj` names a pattern, not a file; test it as a concrete basename.
names = [n.replace('*', 'x') for n in re.findall(r'`([^`]+)`', m.group(1))]
body = sys.argv[2][len('(^|/)('):-len(')$')]
alts, depth, cur = [], 0, ''
for ch in body:  # split on top-level '|' only; nested groups keep theirs
    if ch == '|' and depth == 0:
        alts.append(cur); cur = ''
        continue
    depth += (ch == '(') - (ch == ')')
    cur += ch
alts.append(cur)
unmatched = [n for n in names if not any(re.fullmatch(a, n) for a in alts)]
missing = [a for a in alts if not any(re.fullmatch(a, n) for n in names)]
if unmatched: print("in the prose list but not the regex:", unmatched)
if missing: print("in the regex but not the prose list:", missing)
sys.exit(1 if unmatched or missing else 0)
PY
then
  echo "PASS: scanner prose basename list and the Step 1 regex name the same files"; pass=$((pass+1))
else
  echo "FAIL: scanner prose basename list and the Step 1 regex disagree"; fail=$((fail+1))
fi

# check 6: every fixture holding a language manifest from the scanner's `runtime` evidence table
# (agents/repo-context-scanner.md) has at least one identity input. The regex once omitted Gemfile,
# composer.json and setup.py, so every Ruby, PHP or setup.py-only Python service without a Dockerfile was "uncovered" under the
# #150 rule and re-scanned on every command: the cache could never hit. Fixtures with no manifest
# (java-greenfield is a bare App.java the e2e compiles directly) aren't detected as services at
# all, so they have nothing to cover; keycloak-deployment must stay uncovered (check 4).
MANIFEST='(^|/)(package\.json|pyproject\.toml|requirements\.txt|setup\.py|pom\.xml|build\.gradle(\.kts)?|[^/]+\.(csproj|fsproj)|go\.mod|Gemfile|composer\.json|Cargo\.toml)$'
uncovered=""
for d in fixtures/*/; do
  name=$(basename "$d")
  files=$(cd "$d" && find . -type f | sed 's|^\./||')
  echo "$files" | grep -qE "$MANIFEST" || continue
  if ! echo "$files" | grep -qE "$REGEX"; then
    uncovered="$uncovered $name"
  fi
done
if [ -z "$uncovered" ]; then
  echo "PASS: every fixture with a language manifest has an identity input"; pass=$((pass+1))
else
  echo "FAIL: fixtures with no identity input (cache would always read stale):$uncovered"; fail=$((fail+1))
fi

# --- #208: test projects / tooling-only manifests must be excluded from identityInputs, in
# lockstep between /otel-init Step 1 and the scanner's prose, the same way check 0 guards the
# include regex above. ---
EXCLUDE='(^|/)[^/]*[Tt]ests?\.(csproj|fsproj)$|(^|/)[Tt]ests?/'

if grep -qF "$EXCLUDE" "$INIT"; then
  echo "PASS: /otel-init Step 1 carries exactly the test/tooling EXCLUDE pattern this test mirrors"; pass=$((pass+1))
else
  echo "FAIL: /otel-init Step 1 EXCLUDE pattern differs from this test's mirror — update it (#208)"; fail=$((fail+1))
fi
if grep -qF "$EXCLUDE" "$SCANNER"; then
  echo "PASS: scanner carries exactly the same EXCLUDE pattern, in lockstep with /otel-init (#208)"; pass=$((pass+1))
else
  echo "FAIL: scanner's EXCLUDE pattern differs from /otel-init Step 1 — the two sets will never agree (#208)"; fail=$((fail+1))
fi

# check: applying REGEX then EXCLUDE to the real #94 dotnet-testproject fixture drops its test
# .csproj entirely — proof the pipeline (not just the pattern text) does what #208 asks.
TESTPROJ_DIR="fixtures/dotnet-testproject"
testproj_survivors=$(cd "$TESTPROJ_DIR" && find . -type f | sed 's|^\./||' | grep -E "$REGEX" | grep -vE "$EXCLUDE" || true)
if [ -d "$TESTPROJ_DIR" ] && [ -z "$testproj_survivors" ]; then
  echo "PASS: REGEX+EXCLUDE drops the dotnet-testproject fixture's test .csproj entirely (#208)"; pass=$((pass+1))
else
  echo "FAIL: dotnet-testproject fixture still has identity inputs after EXCLUDE ($testproj_survivors) — #208 regression"; fail=$((fail+1))
fi

# check: otel-init documents identityExclude as ADDITIVE to the defaults, and the scanner says
# the same — a repo adding its own pattern must not accidentally lose the built-in test coverage.
if grep -qiF "identityExclude\` is additive" "$INIT" && grep -qF "additive to the two patterns above" "$SCANNER"; then
  echo "PASS: identityExclude is documented as additive to the defaults on both sides (#208)"; pass=$((pass+1))
else
  echo "FAIL: identityExclude's additive-not-replacing contract is missing on one side (#208)"; fail=$((fail+1))
fi


# --- #225: the fingerprint hash must be shell-neutral (no sha256sum/cut, which don't exist on
# Windows PowerShell), and both files must define it the SAME way ---
PY_FINGERPRINT_CMD='git hash-object --stdin-paths | python3 -c "import sys,hashlib; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest()[:16])"'

if ! grep -qF "sha256sum | cut -c1-16" "$INIT" && ! grep -qF "sha256sum | cut -c1-16" "$SCANNER"; then
  echo "PASS: neither file defines the fingerprint via sha256sum/cut any more (#225)"; pass=$((pass+1))
else
  echo "FAIL: sha256sum | cut -c1-16 still appears somewhere — not shell-neutral (#225)"; fail=$((fail+1))
fi

if grep -qF "$PY_FINGERPRINT_CMD" "$INIT" && grep -qF "$PY_FINGERPRINT_CMD" "$SCANNER"; then
  echo "PASS: otel-init and the scanner define the IDENTICAL python3 fingerprint command (#225)"; pass=$((pass+1))
else
  echo "FAIL: the python3 fingerprint command is missing or differs between the two files (#225)"; fail=$((fail+1))
fi

if grep -qF "do not exist on Windows PowerShell" "$INIT"; then
  echo "PASS: otel-init explains python3 replaces sha256sum/cut because they don't exist on PowerShell (#225)"; pass=$((pass+1))
else
  echo "FAIL: otel-init no longer explains why python3 replaces sha256sum/cut (#225)"; fail=$((fail+1))
fi

if grep -qF "read and concatenate each file" "$INIT" && grep -qF "read and concatenate the files" "$SCANNER"; then
  echo "PASS: the non-git-repo fallback (read+concatenate bytes, same sorted order, SHA-256) is defined on both sides (#225)"; pass=$((pass+1))
else
  echo "FAIL: the non-git-repo fallback definition is missing on one side (#225)"; fail=$((fail+1))
fi

# #226 review: the fingerprint command's duplication-with-parity-test is deliberate (mirrors the
# pre-existing identityInputs regex lockstep just above it), not a smell to collapse into a
# Read-able path reference -- both files must say so explicitly, or a later editor "fixes" it
# into an inconsistency with its own sibling rule.
if grep -qF "the SAME lockstep" "$SCANNER" && grep -qF "not a new duplication to prune" "$SCANNER"; then
  echo "PASS: scanner explains the fingerprint duplication mirrors the identityInputs lockstep, on purpose"; pass=$((pass+1))
else
  echo "FAIL: scanner no longer explains why the fingerprint duplication is intentional"; fail=$((fail+1))
fi
if grep -qF "kept as two copies in" "$INIT" && grep -qF "not a reference to it" "$INIT"; then
  echo "PASS: otel-init explains the fingerprint duplication mirrors the identityInputs lockstep, on purpose"; pass=$((pass+1))
else
  echo "FAIL: otel-init no longer explains why the fingerprint duplication is intentional"; fail=$((fail+1))
fi

# Teeth: prove the python3 replacement is actually byte-identical to the old sha256sum|cut
# pipeline it replaces, not just plausible-sounding prose.
OLD_HASH="$(git hash-object .claude/CLAUDE.md AGENTS.md | sha256sum | cut -c1-16)"
NEW_HASH="$(printf '.claude/CLAUDE.md\nAGENTS.md\n' | git hash-object --stdin-paths | python3 -c "import sys,hashlib; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest()[:16])")"
if [ "$OLD_HASH" = "$NEW_HASH" ]; then
  echo "PASS: teeth: the python3 fingerprint command reproduces the exact same hash as sha256sum|cut did (#225)"; pass=$((pass+1))
else
  echo "FAIL: teeth: python3 fingerprint ($NEW_HASH) diverges from the old sha256sum|cut result ($OLD_HASH) (#225)"; fail=$((fail+1))
fi

echo ""
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
