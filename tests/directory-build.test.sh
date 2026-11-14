#!/usr/bin/env bash
# tests/directory-build.test.sh: offline checks on the slim folder scripts/build-directory.sh makes
# for Anthropic's plugin directory (the `directory` branch). People who install from the directory
# get only that folder, so a file the plugin names at run time but the build leaves out is a
# broken install that no other test would catch.
set -uo pipefail
cd "$(dirname "$0")/.."
PASS=0; FAIL=0
check() { if eval "$2"; then echo "PASS: $1"; PASS=$((PASS+1)); else echo "FAIL: $1"; FAIL=$((FAIL+1)); fi; }

OUT=$(mktemp -d)/plugin
trap 'rm -rf "$(dirname "$OUT")"' EXIT
bash scripts/build-directory.sh "$OUT" || { echo "FAIL: build-directory.sh exited non-zero"; exit 1; }

check "manifest is present" '[ -f "$OUT/.claude-plugin/plugin.json" ]'
check "manifest version matches the source" \
  '[ "$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))[\"version\"])" "$OUT/.claude-plugin/plugin.json")" = "$(python3 -c "import json; print(json.load(open(\".claude-plugin/plugin.json\"))[\"version\"])")" ]'
check "no marketplace.json (the folder must read as one plugin)" '[ ! -e "$OUT/.claude-plugin/marketplace.json" ]'
check "README, LICENSE and backends.txt are present" '[ -f "$OUT/README.md" ] && [ -f "$OUT/LICENSE" ] && [ -f "$OUT/backends.txt" ]'
check "every command, agent and skill ships" \
  '[ "$(git ls-files commands agents skills | wc -l)" -eq "$(cd "$OUT" && find commands agents skills -type f | wc -l)" ]'
check "no development tree (fixtures, tests, evals, .github, .agents, hooks/codex, node_modules)" \
  '[ -z "$(cd "$OUT" && find . \( -name fixtures -o -name tests -o -name evals -o -name .github -o -name .agents -o -name node_modules -o -path ./hooks/codex \) -print)" ]'
check "no __pycache__ or .DS_Store" '[ -z "$(find "$OUT" \( -name __pycache__ -o -name .DS_Store \) -print)" ]'
check "512 files or fewer (the directory holds a bigger plugin for review)" '[ "$(find "$OUT" -type f | wc -l)" -le 512 ]'
check "every non-image file is under 256 KiB" \
  '[ -z "$(find "$OUT" -type f ! -name "*.png" -size +256k -print)" ]'

# Every ${CLAUDE_PLUGIN_ROOT}/<path> the shipped files name must exist in the build. Placeholders
# such as <name> are skipped; a trailing backtick, quote or punctuation is not part of the path.
missing=$(cd "$OUT" && grep -rhoE '\$\{CLAUDE_PLUGIN_ROOT\}/[A-Za-z0-9_./-]+' . \
  | sed -E 's#^\$\{CLAUDE_PLUGIN_ROOT\}/##; s#[.,;:]+$##' | grep -v '<' | sort -u \
  | while read -r p; do [ -e "$p" ] || echo "$p"; done)
check "every \${CLAUDE_PLUGIN_ROOT} path the plugin names ships${missing:+ (missing: $(echo $missing))}" '[ -z "$missing" ]'

# The README is the listing text, so its links must not point at files the build leaves out.
rel=$(grep -oE '\]\([^)]+\)' "$OUT/README.md" | grep -vE '^\]\((https?:|mailto:|#)' || true)
check "README has no relative links${rel:+ (found: $(echo $rel))}" '[ -z "$rel" ]'

check "hooks name every program they run" \
  '! grep -nE "\"\\\$PY\" (-c|\")|\\\$\\(dirname \"\\\$\\{BASH_SOURCE\\[0\\]\\}\"\\)/[a-z]" "$OUT"/hooks/*.sh | grep -v "CLAUDE_PLUGIN_ROOT=\"" >/dev/null'

echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
