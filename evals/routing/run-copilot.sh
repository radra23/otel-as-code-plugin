#!/usr/bin/env bash
# Condition (c) runner: one fresh non-interactive GitHub Copilot CLI session with ONLY this
# plugin installed, on the same scaffold, prompt and timeout as conditions (a) and (b).
#
# usage: run-copilot.sh <case-dir> <run-index> <out-dir>
# writes <out-dir>/<case>/run-<n>/{copilot.jsonl,trace.jsonl,stderr.log,meta.json}
#
# Isolation: HOME and COPILOT_HOME are a fresh temp dir per run, so no personal skill
# (~/.agents/skills), custom agent, plugin, MCP config or memory loads; only Copilot's built-ins
# and this plugin. The plugin is installed from a `git archive` of HEAD, the way a user's install
# carries only tracked files, so commit what you want measured.
# Auth: COPILOT_GITHUB_TOKEN when set (CI); otherwise the token of your `gh` login, passed in the
# environment of the Copilot process only. A temp HOME hides Copilot's own stored login.
# Scoring: copilot_trace.py rewrites Copilot's JSON events into the stream-json tool calls
# score.py reads, so all three conditions are scored by the same unchanged rules.
set -uo pipefail
CASE_DIR=$(cd "$1" && pwd); RUN=$2; OUT_ROOT=$3
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; ROOT="$(cd "$HERE/../.." && pwd)"
COPILOT=${COPILOT_BIN:-copilot}
MODEL=${COPILOT_MODEL:-gpt-4.1}
CASE=$(basename "$CASE_DIR")
OUT="$OUT_ROOT/$CASE/run-$RUN"; mkdir -p "$OUT"; OUT=$(cd "$OUT" && pwd)
PROMPT=$(awk 'f==2{print} /^---$/{f++}' "$CASE_DIR/prompt.md" | sed '/./,$!d')
TIMEOUT=$(sed -n 's/^timeout_seconds: *//p' "$CASE_DIR/prompt.md"); TIMEOUT=${TIMEOUT:-300}
TOKEN=${COPILOT_GITHUB_TOKEN:-$(gh auth token 2>/dev/null)}
[ -n "$TOKEN" ] || { echo "no COPILOT_GITHUB_TOKEN and no gh login" >&2; exit 1; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/otel-routing-c.XXXXXX"); TMP=$(cd "$TMP" && pwd -P)
WS="$TMP/work/checkout-api"; mkdir -p "$WS" "$TMP/home" "$TMP/market"
(cd "$WS" && bash "$HERE/scaffold.sh") || { echo "scaffold failed" >&2; exit 1; }
git -C "$ROOT" archive HEAD | tar -x -C "$TMP/market"
c() { HOME="$TMP/home" COPILOT_HOME="$TMP/home/.copilot" COPILOT_GITHUB_TOKEN="$TOKEN" "$COPILOT" "$@"; }
{ c plugin marketplace add "$TMP/market" && c plugin install otel-as-code@otel-as-code; } \
  > "$OUT/install.log" 2>&1 || { echo "plugin install failed, see $OUT/install.log" >&2; exit 1; }

ALLOW=(--allow-tool=write)
for cmd in node npm npx curl git ls cat head tail grep find sed wc jq python3 kill pkill lsof ps \
           sleep echo printf date mkdir test sort; do ALLOW+=("--allow-tool=shell($cmd:*)"); done

START=$(date +%s)
( cd "$WS" && exec env HOME="$TMP/home" COPILOT_HOME="$TMP/home/.copilot" COPILOT_GITHUB_TOKEN="$TOKEN" \
    "$COPILOT" -p "$PROMPT" --model "$MODEL" --output-format json --no-auto-update --no-ask-user \
    "${ALLOW[@]}" ) > "$OUT/copilot.jsonl" 2> "$OUT/stderr.log" &
PID=$!
( sleep "$TIMEOUT"; kill "$PID" 2>/dev/null && echo "timed out after ${TIMEOUT}s" >> "$OUT/stderr.log" ) &
WATCH=$!
wait "$PID"; RC=$?
kill "$WATCH" 2>/dev/null; wait "$WATCH" 2>/dev/null
END=$(date +%s)
PLUGIN_ROOT="$TMP/home/.copilot/installed-plugins/otel-as-code/otel-as-code"
python3 "$HERE/copilot_trace.py" "$OUT/copilot.jsonl" "$PLUGIN_ROOT" > "$OUT/trace.jsonl"
python3 - "$OUT" "$CASE" "$RUN" "$RC" "$((END-START))" "$MODEL" <<'PY'
import json, sys
out, case, run, rc, secs, model = sys.argv[1:]
prem, limited = None, []
for line in open(f"{out}/copilot.jsonl", errors="replace"):
    try: e = json.loads(line)
    except ValueError: continue
    if e.get("type") == "result": prem = (e.get("usage") or {}).get("premiumRequests")
    d = e.get("data") or {}
    if e.get("type") == "model.call_failure" and d.get("statusCode") == 429:
        limited.append(str(d.get("errorMessage", ""))[:200])
# Copilot exits 0 after its model calls are rate limited, having done nothing; scored as is, that
# reads as a real "neither". Record it as a failed run so score.py counts it as an error.
if limited and int(rc) == 0:
    rc = "75"
    open(f"{out}/stderr.log", "a").write("rate limited (HTTP 429): " + limited[0] + "\n")
# costUsd stays null: Copilot bills premium requests, not dollars, so it is recorded on its own.
json.dump({"condition": "c", "case": case, "run": int(run), "exitCode": int(rc),
           "durationSeconds": int(secs), "costUsd": None, "premiumRequests": prem, "model": model},
          open(f"{out}/meta.json", "w"))
print(f"  c {case} run {run}: {prem} premium requests {secs}s exit {rc}"
      + (" RATE LIMITED" if limited else ""))
sys.exit(75 if limited else 0)
PY
LIMITED=$?
pkill -f "$WS" 2>/dev/null || true
rm -rf "$TMP"
# 255 makes run.sh's xargs stop starting runs: every later run would hit the same limit.
[ "$LIMITED" -eq 75 ] && { echo "Copilot rate limit reached; stopping the pass" >&2; exit 255; }
exit 0
