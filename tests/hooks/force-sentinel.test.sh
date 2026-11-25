#!/usr/bin/env bash
# tests/hooks/force-sentinel.test.sh
# #255: scripts/otel_force.py is the one writer of the --force sentinel (.claude/.otel-force).
#   - No command, agent or skill writes or removes the sentinel by hand any more: the snippets
#     used to differ (`printf ... >` in one command, `:>` then `>>` in another).
#   - Every command that authorises a --force overwrite calls `otel_force.py set` and `clear`.
#   - set replaces any earlier sentinel and stamps an expiry; hooks/otel-force-match.py refuses
#     an expired sentinel and still honours one with no expiry line (an older version's).
#   - End to end through hooks/write-guard.sh with the real tool_name/tool_input payload: the
#     overwrite of a marker-carrying generated file is allowed while the sentinel is live and
#     blocked once it has expired or been cleared.
set -uo pipefail
cd "$(dirname "$0")/../.."
ROOT=$PWD
FORCE="$ROOT/scripts/otel_force.py"
pass=0; fail=0
check() { if eval "$2"; then echo "PASS: $1"; pass=$((pass+1)); else echo "FAIL: $1"; fail=$((fail+1)); fi; }

# ---------------------------------------------------------------- nothing writes it by hand
HAND='(>>?|:>) *[^ ]*\.claude/\.otel-force|rm -f [^ ]*\.claude/\.otel-force'
check "no command, agent or skill writes or removes .claude/.otel-force by hand" \
  '! grep -rnE "$HAND" commands agents skills .agents'
for c in otel-instrument otel-collector otel-backend otel-local; do
  check "commands/$c.md sets the sentinel through otel_force.py set" \
    'grep -qF "\"\${CLAUDE_PLUGIN_ROOT}/scripts/otel_force.py\" set " commands/$c.md'
  check "commands/$c.md clears it through otel_force.py clear" \
    'grep -qF "\"\${CLAUDE_PLUGIN_ROOT}/scripts/otel_force.py\" clear" commands/$c.md'
done
check "the slim directory build ships the script" 'grep -qF "scripts/otel_force.py" scripts/build-directory.sh'

# ---------------------------------------------------------------- the script itself
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
cd "$T"
mkdir -p infra
printf 'stale\n' > leftover-target
python3 "$FORCE" set leftover-target >/dev/null
python3 "$FORCE" set infra/main.tf infra/variables.tf >/dev/null
# Python's abspath spells the directory physically (macOS: /private/var, not $PWD's /var); the
# matcher resolves both spellings, so the expected value is the physical one.
HERE=$(pwd -P)
check "set writes one expiry line, then each path absolute, replacing any earlier sentinel" \
  '[ "$(sed -n 1p .claude/.otel-force | cut -d" " -f1-5)" = "# otel-as-code --force sentinel; expires" ] && [ "$(sed -n 2p .claude/.otel-force)" = "$HERE/infra/main.tf" ] && [ "$(sed -n 3p .claude/.otel-force)" = "$HERE/infra/variables.tf" ] && [ "$(wc -l < .claude/.otel-force | tr -d " ")" = 3 ]'
out=$(python3 "$FORCE" set 2>&1); rc=$?
check "set with no path exits 1 and writes nothing new" '[ "$rc" = 1 ] && grep -q "needs at least one path" <<<"$out" && [ "$(wc -l < .claude/.otel-force | tr -d " ")" = 3 ]'
python3 "$FORCE" clear; python3 "$FORCE" clear; rc=$?
check "clear removes the sentinel, and clearing again is not an error" '[ "$rc" = 0 ] && [ ! -e .claude/.otel-force ]'

# A planted symlink at the sentinel is replaced, never followed to the file it points at.
printf 'precious\n' > "$T/precious"
python3 "$FORCE" clear; ln -s "$T/precious" .claude/.otel-force
python3 "$FORCE" set infra/main.tf >/dev/null
check "set replaces a symlink planted at .claude/.otel-force instead of writing through it" \
  '[ "$(cat "$T/precious")" = precious ] && [ ! -L .claude/.otel-force ] && grep -qF "$HERE/infra/main.tf" .claude/.otel-force'
mkdir -p "$T/elsewhere" sub; ln -s "$T/elsewhere" sub/.claude
out=$(cd sub && python3 "$FORCE" set x 2>&1); rc=$?
check "set refuses a symlinked .claude directory and writes nothing there" \
  '[ "$rc" = 1 ] && grep -q "is a symlink" <<<"$out" && [ -z "$(ls -A "$T/elsewhere")" ]'
# A path that does not come back from the matcher's splitlines() as exactly itself is refused,
# so a line break cannot smuggle in a second entry.
before=$(cat .claude/.otel-force)
for bad in "$(printf 'infra/a.tf\n/etc/passwd')" "$(printf 'infra/a.tf\r/etc/passwd')" "infra/a.tf$(printf '\342\200\250')/etc/passwd" "infra/a.tf "; do
  out=$(python3 "$FORCE" set "$bad" 2>&1); rc=$?
  check "set refuses a path that is not one clean line ($(printf '%q' "$bad"))" \
    '[ "$rc" = 1 ] && grep -q "not one clean line" <<<"$out" && [ "$(cat .claude/.otel-force)" = "$before" ]'
done

# The matcher turns a backslash into a separator and collapses `..`, so on a POSIX host a
# backslash in a name would be matched as a different, wider path: refused. A real `..` is fine,
# because abspath collapses it before the entry is written.
out=$(python3 "$FORCE" set 'infra\..\..\etc\x' 2>&1); rc=$?
check "set refuses a path with a backslash on a POSIX host (the matcher would read it as /etc/x)" \
  '[ "$rc" = 1 ] && grep -q "backslash" <<<"$out" && [ "$(cat .claude/.otel-force)" = "$before" ]'
mkdir -p infra/sub
python3 "$FORCE" set infra/sub/../main.tf >/dev/null
check "a real .. is collapsed before the entry is written" \
  '[ "$(sed -n 2p .claude/.otel-force)" = "$HERE/infra/main.tf" ]'

M="$ROOT/hooks/otel-force-match.py"
touch infra/main.tf
python3 "$FORCE" set infra/main.tf >/dev/null
check "the matcher allows a listed path while the sentinel is live" 'python3 "$M" "$PWD/infra/main.tf" "$PWD" .claude/.otel-force'
check "and refuses a path it does not list" '! python3 "$M" "$PWD/infra/outputs.tf" "$PWD" .claude/.otel-force'
python3 "$FORCE" set --ttl -1 infra/main.tf >/dev/null
check "the matcher refuses an expired sentinel" '! python3 "$M" "$PWD/infra/main.tf" "$PWD" .claude/.otel-force'
printf '%s\n' "$PWD/infra/main.tf" > .claude/.otel-force
check "a sentinel with no expiry line (an older version's) is still honoured" 'python3 "$M" "$PWD/infra/main.tf" "$PWD" .claude/.otel-force'

# ---------------------------------------------------------------- end to end through write-guard
printf '# Generated by otel-as-code v0.0.0\nresource "x" "y" {}\n' > infra/main.tf
guard() {   # exit code of write-guard for a Write of infra/main.tf
  local rc=0
  printf '{"tool_name":"Write","tool_input":{"file_path":"%s"}}' "$PWD/infra/main.tf" \
    | CLAUDE_PROJECT_DIR="$PWD" CLAUDE_PLUGIN_ROOT="$ROOT" bash "$ROOT/hooks/write-guard.sh" >/dev/null 2>&1 || rc=$?
  echo "$rc"
}
python3 "$FORCE" clear
check "write-guard blocks the overwrite with no sentinel" '[ "$(guard)" = 2 ]'
python3 "$FORCE" set infra/main.tf >/dev/null
check "write-guard allows it once otel_force.py set lists the file" '[ "$(guard)" = 0 ]'
python3 "$FORCE" set --ttl -1 infra/main.tf >/dev/null
check "write-guard blocks it again once that sentinel has expired" '[ "$(guard)" = 2 ]'
python3 "$FORCE" set infra/main.tf >/dev/null; python3 "$FORCE" clear
check "and once it has been cleared" '[ "$(guard)" = 2 ]'

echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
