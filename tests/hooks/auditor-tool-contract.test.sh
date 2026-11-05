#!/usr/bin/env bash
# tests/hooks/auditor-tool-contract.test.sh
# Locks #222: brownfield-auditor.md declares tools: Read, Grep, Glob but dimension 8's credential
# check instructed `git ls-files`/`git check-ignore`/`git log --all -S`, which it cannot run. The
# fix does NOT widen the auditor's tools (that would reopen the vendor-neutral, read-only-auditor
# boundary this plugin holds deliberately) -- /otel-evaluate runs the git checks itself and hands
# the auditor the result as an explicit fact (gitFileStatus), the same pattern already used for
# bootstrapHealth (#194). This test both checks the specific fix and guards the general class: no
# agent file that declares a tool list without Bash may instruct running a shell/git command as
# something IT does.
set -uo pipefail
cd "$(dirname "$0")/../.."
pass=0; fail=0
check() { if eval "$2"; then echo "PASS: $1"; pass=$((pass+1)); else echo "FAIL: $1"; fail=$((fail+1)); fi; }

AUDITOR="agents/brownfield-auditor.md"
EVAL="commands/otel-evaluate.md"

check "brownfield-auditor's tools were NOT widened to include Bash" \
  'grep -qF "tools: Read, Grep, Glob" "$AUDITOR" && ! grep -qE "^tools:.*Bash" "$AUDITOR"'

check "dimension 8 states plainly that the auditor has no Bash tool" \
  'grep -qF "You have no \`Bash\` tool** (#222)" "$AUDITOR"'

check "dimension 8 defers git-tracked / gitignored lookups to the passed-in gitFileStatus fact" \
  'grep -qF "gitFileStatus[<file>].tracked" "$AUDITOR" && grep -qF "gitFileStatus[<file>].gitignored" "$AUDITOR"'

check "dimension 8 explicitly says not to run git ls-files / git check-ignore itself" \
  'grep -qF "do NOT run" "$AUDITOR" && grep -qF "yourself, you cannot" "$AUDITOR"'

check "dimension 8 defers the ever-committed (git log -S) check to the dispatching command" \
  'grep -qF "ever-committed: not checked" "$AUDITOR" \
   && grep -qF "the command checks it after you return" "$AUDITOR"'

check "the Input section documents gitFileStatus as a fact, not a claim to re-derive" \
  'grep -qF "\`gitFileStatus\` (optional)" "$AUDITOR" \
   && grep -qF "you have no \`Bash\` tool, so \`git ls-files\` / \`git check-ignore\` are commands you cannot run" "$AUDITOR"'

check "the Credential Exposure worked example no longer claims the auditor ran git log itself" \
  'grep -qF "(from gitFileStatus) / ever-committed: not" "$AUDITOR" \
   && grep -qF "checked by this report. So: ROTATE" "$AUDITOR"'

check "the cached-judgement refutation example no longer claims the auditor ran git log itself" \
  'grep -qF "ever-committed question itself is for the dispatching command to settle via" "$AUDITOR"'

# --- /otel-evaluate side: it actually computes and passes the fact, and resolves the deferred check ---
check "otel-evaluate Step 2 computes gitFileStatus via git ls-files / git check-ignore" \
  'grep -qF "git ls-files --error-unmatch" "$EVAL" && grep -qF "git check-ignore -q" "$EVAL"'

check "otel-evaluate Step 4 passes gitFileStatus to the auditor" \
  'grep -qF "\`gitFileStatus\`: the map built in Step 2" "$EVAL"'

check "otel-evaluate Step 5 resolves the ever-committed fact via git log -S before printing" \
  'grep -qF "git log --all -S" "$EVAL"'

# --- general regression guard: no Bash-less agent instructs running git/shell as its own job ---
# A line naming `git ls-files` / `git check-ignore` / `git log` in a Bash-less agent file is only
# safe when it is clearly attributed as something the agent CANNOT do / the command does instead
# -- checked via nearby context, not line-exact phrasing, since the attribution wording is prose.
GIT_CMD_GUARD_RESULT="$(python3 - <<'PYEOF'
import glob, re

bad = []
for path in sorted(glob.glob("agents/*.md")):
    with open(path) as f:
        text = f.read()
    m = re.search(r"^tools:\s*(.*)$", text, re.MULTILINE)
    if not m or "Bash" in m.group(1):
        continue  # no tools: line means every tool (incl. Bash); Bash-having agents are out of scope
    lines = text.splitlines()
    for i, line in enumerate(lines):
        if re.search(r"git (ls-files|check-ignore|log)\b", line):
            window = "\n".join(lines[max(0, i - 2):i + 3])
            if not re.search(r"cannot run|do NOT run|dispatching command|the command checks", window):
                bad.append(f"{path}:{i+1}: {line.strip()}")

if bad:
    print("BAD:" + " | ".join(bad))
else:
    print("OK")
PYEOF
)"
check "teeth: no Bash-less agent file instructs a git command as its own unattributed action" \
  '[ "$GIT_CMD_GUARD_RESULT" = "OK" ]'

echo
echo "auditor-tool-contract: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
