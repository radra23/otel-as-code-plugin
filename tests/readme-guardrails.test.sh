#!/usr/bin/env bash
# tests/readme-guardrails.test.sh
# Locks #252: the README's Guardrails section must say what each agent actually runs. Which agent
# runs a hook is read from hooks/hooks.json, .codex/hooks.json and the root hooks.json (Copilot
# CLI), and which commands take
# --dry-run from each command's argument-hint, so a hook or flag added later can't leave the
# README describing something that isn't there.
set -uo pipefail
cd "$(dirname "$0")/.."
pass=0; fail=0
check() { if eval "$2"; then echo "PASS: $1"; pass=$((pass+1)); else echo "FAIL: $1"; fail=$((fail+1)); fi; }

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

# section <heading>: the README text from "## <heading>" up to the next "## " heading.
section() {
  python3 -c '
import re, sys
text = open("README.md", encoding="utf-8").read()
m = re.search(r"^## " + re.escape(sys.argv[1]) + r"\n(.*?)(?=^## )", text, re.S | re.M)
print(m.group(1) if m else "")
' "$1"
}
# bullet <name>: one "- **<name>" bullet of the Guardrails section, joined onto one line.
bullet() {
  section Guardrails | python3 -c '
import sys
out, on = [], False
for line in sys.stdin.read().splitlines():
    if line.startswith("- **"):
        on = line.startswith("- **" + sys.argv[1])
    elif not line.strip():
        on = False
    if on:
        out.append(line.strip())
print(" ".join(out))
' "$1"
}
# codex_runs <hook script>: true when .codex/hooks.json has the event hooks/hooks.json runs it on.
codex_runs() {
  python3 -c '
import json, sys
claude = json.load(open("hooks/hooks.json"))["hooks"]
codex = json.load(open(".codex/hooks.json"))["hooks"]
events = [ev for ev, groups in claude.items()
          if any(sys.argv[1] in h.get("command", "") for g in groups for h in g["hooks"])]
assert events, "hook not registered in hooks/hooks.json: " + sys.argv[1]
sys.exit(0 if all(ev in codex for ev in events) else 1)
' "$1"
}

# copilot_runs <hook script>: true when the root hooks.json (Copilot CLI's flat format) runs an
# adapter in hooks/copilot/ that runs the script.
copilot_runs() {
  python3 -c '
import json, os, re, sys
cfg = json.load(open("hooks.json"))["hooks"]
for groups in cfg.values():
    for h in groups:
        for path in re.findall(r"hooks/copilot/[\w.-]+\.py", h.get("bash", "")):
            if sys.argv[1] in open(path, encoding="utf-8").read():
                sys.exit(0)
sys.exit(1)
' "$1"
}
# agents_for <hook script>: "Claude Code", then each other agent whose config runs it.
agents_for() {
  local a="Claude Code"
  codex_runs "$1" && a="$a|Codex"
  copilot_runs "$1" && a="$a|Copilot CLI"
  echo "$a"
}
# label <a|b|c>: "(Claude Code only)", "(Claude Code and Codex)", "(Claude Code, Codex and Copilot CLI)".
label() {
  python3 -c '
import sys
a = sys.argv[1].split("|")
print("(" + (a[0] + " only" if len(a) == 1 else ", ".join(a[:-1]) + " and " + a[-1]) + ")")
' "$1"
}

section Guardrails > "$TMPD/guardrails.txt"
section "Using with Codex" > "$TMPD/codex.txt"
check "the README has a Guardrails section and a Using with Codex section" \
  '[ -s "$TMPD/guardrails.txt" ] && [ -s "$TMPD/codex.txt" ]'

# Each hook bullet names the agents it runs in, and the label matches the two hook configs.
claude_only=0
for pair in "Write guard:write-guard.sh" "Semconv lint:semconv-lint.sh" "Session summary:session-summary.sh"; do
  name=${pair%%:*}; script=${pair#*:}
  codex_runs "$script" || claude_only=1
  label=$(label "$(agents_for "$script")")
  b=$(bullet "$name")
  check "the $name bullet says $label, as the hook configs register it (#252)" \
    '[ -n "$b" ] && case "$b" in *"$label"*) true ;; *) false ;; esac'
done
if [ "$claude_only" -eq 1 ]; then
  check "the Guardrails section does not say every guardrail runs in both agents" \
    '! grep -qi "in both Claude Code and Codex" "$TMPD/guardrails.txt"'
  check "Using with Codex says the session summary does not run there" \
    'grep -qi "session summary" "$TMPD/codex.txt" && ! grep -qi "the one difference" "$TMPD/codex.txt"'
fi

# Codex finds the hook adapters from the git root, so a vendored copy runs no hooks.
if grep -q "show-toplevel" .codex/hooks.json; then
  check "Guardrails says the Codex hooks load only when this repo is the project root" \
    'grep -qi "project root" "$TMPD/guardrails.txt"'
  check "Using with Codex says the same" \
    'grep -qi "project root" "$TMPD/codex.txt"'
fi

# --dry-run: the commands the bullet names are exactly the ones whose argument-hint has it.
DRY=$(bullet "\`--dry-run\`")
named=$(echo "${DRY%%can preview*}" | grep -o '/otel-[a-z-]*' | sort -u | tr '\n' ' ')
actual=$(grep -l -- '^argument-hint:.*--dry-run' commands/*.md | sed 's#commands/#/#; s#\.md$##' | sort -u | tr '\n' ' ')
# Copilot CLI: the install commands use the real marketplace and plugin names, and the section
# says what does not run there.
section "Using with GitHub Copilot CLI" > "$TMPD/copilot.txt"
INSTALL=$(python3 -c '
import json
m = json.load(open(".claude-plugin/marketplace.json"))
print(m["plugins"][0]["name"] + "@" + m["name"])
')
check "the README has a Using with GitHub Copilot CLI section" '[ -s "$TMPD/copilot.txt" ]'
check "it installs with copilot plugin install $INSTALL, the names in marketplace.json" \
  'grep -qF "copilot plugin install $INSTALL" "$TMPD/copilot.txt" && grep -qF "copilot plugin marketplace add radra23/otel-as-code-plugin" "$TMPD/copilot.txt"'
if ! copilot_runs session-summary.sh; then
  check "Using with GitHub Copilot CLI says the session summary does not run there" \
    'grep -qi "session summary" "$TMPD/copilot.txt"'
fi

# The compatibility table: a hook cell says "yes" exactly where that agent's config runs the hook,
# and every file the "Proven by" column names exists.
section "Which agents it works in" > "$TMPD/agents.txt"
check "the README has a Which agents it works in table" 'grep -q "^| Agent |" "$TMPD/agents.txt"'
RUNS=""
for script in write-guard.sh semconv-lint.sh session-summary.sh; do
  codex_runs "$script" && RUNS="$RUNS|Codex:$script"
  copilot_runs "$script" && RUNS="$RUNS|GitHub Copilot CLI:$script"
done
while IFS= read -r line; do
  name=${line#*: }
  case "$line" in PASS:*) check "$name" true ;; *) check "$name" false ;; esac
done < <(RUNS="$RUNS" python3 -c '
import os, re, sys
rows = [l for l in open(sys.argv[1], encoding="utf-8") if l.startswith("|") and not l.startswith("|---")]
split = lambda r: [c.strip() for c in r.strip().strip("|").split("|")]
head, body = split(rows[0]), {split(r)[0]: split(r) for r in rows[1:]}
runs = set(os.environ["RUNS"].split("|"))
hooks = {"Write guard": "write-guard.sh", "Semconv lint": "semconv-lint.sh", "Session summary": "session-summary.sh"}
for name in ("Claude Code", "Codex", "GitHub Copilot CLI"):
    row = body.get(name)
    if row is None:
        print("FAIL: the table has a row for " + name); continue
    for col, script in hooks.items():
        cell = row[head.index(col)].lower()
        expect = name == "Claude Code" or (name + ":" + script) in runs
        print(("PASS" if cell.startswith("yes") == expect else "FAIL")
              + ": the table says " + repr(cell) + " for " + col + " in " + name + ", as the hook configs register it")
for name, row in body.items():
    for path in re.findall(r"`([\w./-]+/[\w./-]*)`", row[head.index("Proven by")]):
        print(("PASS" if os.path.exists(path) else "FAIL") + ": Proven by for " + name + " names " + path + ", which exists")
' "$TMPD/agents.txt")
check "the --dry-run bullet names exactly the commands that take --dry-run ($actual)" \
  '[ -n "$actual" ] && [ "$named" = "$actual" ]'
check "the --dry-run bullet does not claim every writing command has it" \
  '! echo "$DRY" | grep -qi "every writing command"'

# The write guard checks generated names, not any file with the marker: pin the behavior, then
# the wording.
mkdir -p "$TMPD/repo"
echo "# generated by otel-as-code" > "$TMPD/repo/notes.md"
check "write-guard lets a marker-carrying file with a non-generated name be overwritten" \
  'echo "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$TMPD/repo/notes.md\",\"content\":\"x\"}}" \
     | CLAUDE_PROJECT_DIR="$TMPD/repo" bash hooks/write-guard.sh 2>/dev/null'
check "the Write guard bullet does not claim it protects any marker-carrying file" \
  '! bullet "Write guard" | grep -qi "any file that carries"'
check "the Write guard bullet says the no-Python case blocks those names" \
  'bullet "Write guard" | grep -qi "python"'

# Semconv lint gates on OTel API content, and runs after the write, so it can't block it.
check "the Semconv lint bullet does not claim it runs after every write" \
  '! bullet "Semconv lint" | grep -qi "after every write"'
check "the Semconv lint bullet does not claim strict mode blocks the write" \
  '! bullet "Semconv lint" | grep -qiE "violations block|make severe violations block"'

# Session summary reads git status: the whole dirty tree, not only this session.
check "the Session summary bullet says it lists the whole working tree" \
  'bullet "Session summary" | grep -qi "working tree"'

grep -n $'\xe2\x80\x94' "$TMPD/guardrails.txt" "$TMPD/codex.txt" "$TMPD/copilot.txt" "$TMPD/agents.txt" >/dev/null && dash=1 || dash=0
check "no em dashes in the four agent sections" '[ "$dash" -eq 0 ]'

echo
echo "readme-guardrails: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
