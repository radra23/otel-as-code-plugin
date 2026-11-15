#!/usr/bin/env bash
# tests/hooks/semconv-lint-no-python.test.sh
# semconv-lint with no working Python (#253). The lint rules need Python to read the payload, so
# without one nothing is checked. Strict mode must then not block (it used to exit 2 on every
# write, notes.txt included): it reports once, in one plain line, that the checks did not run,
# and exits 0. It must never sound like a check ran.
# Absence is simulated with failing python3/python stubs first on PATH, since the hook runs its
# interpreter only by those literal names; a "resolves but does not run" stub covers the Windows
# Store alias (#54). Payloads are the real PostToolUse shape.
set -uo pipefail
cd "$(dirname "$0")/../.."
HOOK="hooks/semconv-lint.sh"
PASS=0; FAIL=0
check() { if eval "$2"; then echo "PASS: $1"; PASS=$((PASS+1)); else echo "FAIL: $1"; FAIL=$((FAIL+1)); fi; }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/nopy" "$T/stub" "$T/proj/.claude"
for n in python3 python; do
  printf '#!/bin/sh\nexit 127\n' > "$T/nopy/$n"
  printf '#!/bin/sh\necho "Python was not found" >&2\nexit 9\n' > "$T/stub/$n"
  chmod +x "$T/nopy/$n" "$T/stub/$n"
done
# A file with a SEVERE violation (deprecated http.method), so a block would be the old behaviour,
# and a file that has nothing to do with OTel.
printf "const { trace } = require('@opentelemetry/api');\nspan.setAttribute('http.method', 'GET');\n" > "$T/proj/tracing.js"
echo "just notes" > "$T/proj/notes.txt"

payload() {  # real Claude Code PostToolUse payload for a Write of $1. The content is read by the
  # shell: the Windows job's native python cannot open an absolute MSYS /tmp path.
  python3 -c 'import json,sys; p,c=sys.argv[1:3]; print(json.dumps({"session_id":"t","hook_event_name":"PostToolUse","tool_name":"Write","tool_input":{"file_path":p,"content":c},"tool_response":{"filePath":p,"success":True}}))' "$1" "$(cat "$1")"
}
run() {  # $1 = PATH prefix ("" for the real interpreter), rest = env assignments; payload on stdin
  local prefix="$1"; shift
  OUT=$(cd "$T/proj" && env ${prefix:+PATH="$prefix:$PATH"} "$@" bash "$OLDPWD/$HOOK" 2>"$T/err"); RC=$?
  ERR=$(cat "$T/err")
}

# Control: with a working Python this file is blocked in strict mode, so the cases below test the
# missing-Python path, not a file that would have passed anyway.
payload "$T/proj/tracing.js" > "$T/sev.json"
payload "$T/proj/notes.txt" > "$T/notes.json"
run "" OTEL_STRICT=1 < "$T/sev.json"
check "control: strict + working python + severe -> exit 2" '[ "$RC" -eq 2 ]'

for kind in nopy stub; do
  label=$([ "$kind" = nopy ] && echo "no python" || echo "store-stub python")
  for target in sev notes; do
    run "$T/$kind" OTEL_STRICT=1 < "$T/$target.json"
    check "$label + strict + $target -> exit 0 (does not block)" '[ "$RC" -eq 0 ]'
    check "$label + strict + $target -> exactly one line of output" '[ "$(printf "%s\n" "$OUT" "$ERR" | grep -c .)" -eq 1 ]'
    check "$label + strict + $target -> says the strict checks did not run" 'echo "$OUT$ERR" | grep -q "strict mode is on" && echo "$OUT$ERR" | grep -qi "did not run"'
    check "$label + strict + $target -> claims no result" '! echo "$OUT$ERR" | grep -qiE "passed|no violation|clean|severe violation|semconv warning|otel-lint"'
  done
done

# Strict via the .claude/.otel-strict sentinel takes the same path.
touch "$T/proj/.claude/.otel-strict"
run "$T/nopy" CLAUDE_PROJECT_DIR="$T/proj" < "$T/sev.json"
check "no python + .otel-strict sentinel -> exit 0" '[ "$RC" -eq 0 ]'
check "no python + .otel-strict sentinel -> says the strict checks did not run" 'echo "$OUT$ERR" | grep -qi "did not run"'
rm "$T/proj/.claude/.otel-strict"

# Advisory mode is unchanged: skip with exit 0.
run "$T/nopy" < "$T/sev.json"
check "no python + advisory -> exit 0" '[ "$RC" -eq 0 ]'
run "$T/stub" < "$T/sev.json"
check "store-stub python + advisory -> exit 0" '[ "$RC" -eq 0 ]'

echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
