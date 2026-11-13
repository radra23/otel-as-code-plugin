#!/usr/bin/env bash
# Condition (b) runner: one fresh headless Claude Code session under YOUR normal user config
# (every plugin you have enabled), with this checkout's otel-as-code loaded via --plugin-dir
# in place of any installed copy. `claude plugin eval` cannot do this by design: its runs load
# nothing personal. Derived from the trial harness (~/otel-checkout-trial/run-subject.sh).
#
# usage: run-headless.sh <case-dir> <run-index> <out-dir>
# writes <out-dir>/<case>/run-<n>/{trace.jsonl,stderr.log,meta.json,debug.log}
set -uo pipefail
CASE_DIR=$(cd "$1" && pwd); RUN=$2; OUT_ROOT=$3
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; ROOT="$(cd "$HERE/../.." && pwd)"
MODEL=${EVAL_MODEL:-claude-opus-5-5}
CASE=$(basename "$CASE_DIR")
OUT="$OUT_ROOT/$CASE/run-$RUN"; mkdir -p "$OUT"; OUT=$(cd "$OUT" && pwd)
# prompt body and limits come from the same prompt.md that condition (a) uses
PROMPT=$(awk 'f==2{print} /^---$/{f++}' "$CASE_DIR/prompt.md" | sed '/./,$!d')
MAX_TURNS=$(sed -n 's/^max_turns: *//p' "$CASE_DIR/prompt.md"); MAX_TURNS=${MAX_TURNS:-10}
TIMEOUT=$(sed -n 's/^timeout_seconds: *//p' "$CASE_DIR/prompt.md"); TIMEOUT=${TIMEOUT:-300}

WS=$(mktemp -d "${TMPDIR:-/tmp}/otel-routing-b.XXXXXX")/checkout-api; mkdir -p "$WS"
(cd "$WS" && bash "$HERE/scaffold.sh") || { echo "scaffold failed" >&2; exit 1; }

ALLOW=(Read Write Edit Glob Grep Skill Agent TodoWrite
  "Bash(node:*)" "Bash(npm:*)" "Bash(npx:*)" "Bash(curl:*)" "Bash(git:*)" "Bash(ls:*)" "Bash(cat:*)"
  "Bash(head:*)" "Bash(tail:*)" "Bash(grep:*)" "Bash(find:*)" "Bash(sed:*)" "Bash(wc:*)" "Bash(jq:*)"
  "Bash(python3:*)" "Bash(kill:*)" "Bash(pkill:*)" "Bash(lsof:*)" "Bash(ps:*)" "Bash(sleep:*)"
  "Bash(echo:*)" "Bash(printf:*)" "Bash(date:*)" "Bash(mkdir:*)" "Bash(test:*)" "Bash(sort:*)")
SETTINGS='{"enabledPlugins":{"otel-as-code@otel-as-code":false}}'

START=$(date +%s)
( cd "$WS" && exec claude -p "$PROMPT" --model "$MODEL" --max-turns "$MAX_TURNS" \
    --output-format stream-json --verbose --permission-mode acceptEdits \
    --plugin-dir "$ROOT" --settings "$SETTINGS" --debug-file "$OUT/debug.log" \
    --allowedTools "${ALLOW[@]}" ) > "$OUT/trace.jsonl" 2> "$OUT/stderr.log" &
PID=$!
( sleep "$TIMEOUT"; kill "$PID" 2>/dev/null && echo "timed out after ${TIMEOUT}s" >> "$OUT/stderr.log" ) &
WATCH=$!
wait "$PID"; RC=$?
kill "$WATCH" 2>/dev/null; wait "$WATCH" 2>/dev/null
END=$(date +%s)
python3 - "$OUT" "$CASE" "$RUN" "$RC" "$((END-START))" "$MODEL" <<'PY'
import json, sys
out, case, run, rc, secs, model = sys.argv[1:]
cost = None
for line in open(f"{out}/trace.jsonl"):
    try: e = json.loads(line)
    except ValueError: continue
    if e.get("type") == "result": cost = e.get("total_cost_usd")
json.dump({"condition": "b", "case": case, "run": int(run), "exitCode": int(rc),
           "durationSeconds": int(secs), "costUsd": cost, "model": model}, open(f"{out}/meta.json", "w"))
print(f"  b {case} run {run}: ${cost or 0:.2f} {secs}s exit {rc}")
PY
# leave nothing running from this workspace, then remove it
pkill -f "$WS" 2>/dev/null || true
rm -rf "$(dirname "$WS")"
