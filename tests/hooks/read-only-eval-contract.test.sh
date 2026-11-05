#!/usr/bin/env bash
# tests/hooks/read-only-eval-contract.test.sh
# Locks #212: evaluating someone else's repo, or one under a strict change policy, must have a
# path that leaves nothing committed and nothing dirty.
#   - /otel-init --local-ignore must write the ignore rules to .git/info/exclude (untracked,
#     honoured by git identically to .gitignore) instead of the tracked .gitignore.
#   - /otel-evaluate --no-cache-write must scan into memory and never write
#     .claude/otel-context.json, including the Step 5 findings-write-back.
# Also empirically proves the premise these flags rely on: git honours .git/info/exclude exactly
# like .gitignore, so git status stays clean.
set -uo pipefail
cd "$(dirname "$0")/../.."
pass=0; fail=0
check() { if eval "$2"; then echo "PASS: $1"; pass=$((pass+1)); else echo "FAIL: $1"; fail=$((fail+1)); fi; }

INIT="commands/otel-init.md"
EVAL="commands/otel-evaluate.md"

# --- /otel-init --local-ignore ---
check "otel-init documents --local-ignore in argument-hint and a Flags section" \
  'grep -qF "argument-hint: \"[--local-ignore]\"" "$INIT" && grep -qF -- "--local-ignore" "$INIT"'
check "otel-init explains .git/info/exclude is honoured like .gitignore but never tracked" \
  'grep -qF ".git/info/exclude" "$INIT" && grep -qF "never tracked, never shows up in" "$INIT"'
check "otel-init Step 4 branches the ignore-rule target file on --local-ignore (#212)" \
  'grep -qF "Target file: \`.gitignore\` by default, \`.git/info/exclude\` with \`--local-ignore\`" "$INIT"'
check "otel-init does not rewrite a TRACKED blanket .claude rule under --local-ignore" \
  'grep -qF "Exception with \`--local-ignore\`" "$INIT" \
   && grep -qF "do not rewrite it" "$INIT"'
check "otel-init still never puts otel-services.json in either ignore file" \
  'grep -qF "Do NOT add \`.claude/otel-services.json\` to either file" "$INIT"'

# --- /otel-evaluate --no-cache-write ---
check "otel-evaluate documents --no-cache-write in argument-hint and a Flags section" \
  'grep -qF "argument-hint: \"[--no-cache-write]\"" "$EVAL" && grep -qF -- "--no-cache-write" "$EVAL"'
check "otel-evaluate Step 1 skips write_context.py entirely under --no-cache-write" \
  'grep -qF "With \`--no-cache-write\` (#212)" "$EVAL" \
   && grep -qF "skip \`write_context.py\` entirely" "$EVAL"'
check "otel-evaluate Step 1 says the cache is left exactly as found either way" \
  'grep -qF "is left exactly as it was" "$EVAL"'
check "otel-evaluate Step 5 stops before the findings-write-back under --no-cache-write" \
  'grep -qF "stop here" "$EVAL"'

# --- teeth: the flag must actually change behavior, not just get documented and ignored ---
check "teeth: Step 1's write_context.py invocation is conditioned, not unconditional" \
  'grep -qF "Without \`--no-cache-write\`:" "$EVAL"'
check "teeth: Step 5's write-back is conditioned, not unconditional" \
  'grep -qF "Without the flag: write the audit'\''s findings back into the cache" "$EVAL"'

# --- empirical proof of the mechanism both flags rely on ---
TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT
(
  cd "$TMPD"
  git init -q
  git config user.email "test@example.com"
  git config user.name "test"
  echo "x" > tracked.txt
  git add tracked.txt
  git commit -q -m "init"
  mkdir -p .claude
  echo '{"schemaVersion":"1.0"}' > .claude/otel-context.json
  echo ".claude/otel-context.json" >> .git/info/exclude
  echo ".claude/.otel-force" >> .git/info/exclude
)
check "git honours .git/info/exclude: an entry there is ignored (git check-ignore succeeds)" \
  'git -C "$TMPD" check-ignore -q .claude/otel-context.json'
check "git honours .git/info/exclude: the tracked working tree stays clean (git status --porcelain is empty)" \
  '[ -z "$(git -C "$TMPD" status --porcelain)" ]'
check "the tracked .gitignore itself was never touched by the local-ignore mechanism" \
  '[ ! -f "$TMPD/.gitignore" ]'

echo
echo "read-only-eval-contract: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
