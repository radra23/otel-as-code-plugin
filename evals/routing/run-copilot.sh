#!/usr/bin/env bash
# Condition (c) runner: one fresh non-interactive GitHub Copilot CLI session with ONLY this
# plugin installed, on the same scaffold, prompt and timeout as conditions (a) and (b).
#
# usage: run-copilot.sh <case-dir> <run-index> <out-dir>
# writes <out-dir>/<case>/run-<n>/{copilot.jsonl,trace.jsonl,stderr.log,meta.json}, plus
# refusal.json (the first refused model call's data) when Copilot's rate limit refused the run.
# Exit 255 (run.sh discards the run and starts no more) when the run is no measurement at all:
# refused by the rate limit, a setup step failed, or the session never got a fair model call
# (no model turn, or network failures in a session that did not end cleanly). meta.json's
# discardReason says which.
#
# Isolation: HOME and COPILOT_HOME are a fresh temp dir per run, so no personal skill
# (~/.agents/skills), custom agent, plugin, MCP config or memory loads; only Copilot's built-ins
# and this plugin. The plugin is installed from a `git archive` of HEAD, the way a user's install
# carries only tracked files, so commit what you want measured.
# Auth: COPILOT_GITHUB_TOKEN when set (CI); otherwise the token of your `gh` login, passed in the
# environment of the Copilot process only. A temp HOME hides Copilot's own stored login.
# Scoring: copilot_transcript.py rewrites Copilot's JSON events into the stream-json tool calls
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
MAX_TURNS=$(sed -n 's/^max_turns: *//p' "$CASE_DIR/prompt.md"); MAX_TURNS=${MAX_TURNS:-10}
INSTALL_TIMEOUT=${COPILOT_INSTALL_TIMEOUT:-180}
TOKEN=${COPILOT_GITHUB_TOKEN:-$(gh auth token 2>/dev/null)}
[ -n "$TOKEN" ] || { echo "no COPILOT_GITHUB_TOKEN and no gh login (a locked keychain reads as none)" >&2; exit 255; }

# The copilot on PATH can be a wrapper that starts the real CLI as a child (VS Code's is), so
# stopping a session means stopping its whole tree: killing only the wrapper left the session
# running, orphaned, in a workspace this script then deleted.
kill_tree() { local p; for p in $(pgrep -P "$1" 2>/dev/null); do kill_tree "$p"; done; kill "$1" 2>/dev/null; }
with_timeout() {  # seconds, command...: the command's exit code, or 124 once it ran too long
  local secs=$1; shift; "$@" & local p=$!
  ( sleep "$secs"; kill_tree "$p" ) & local w=$!
  wait "$p"; local rc=$?
  if kill -0 "$w" 2>/dev/null; then kill_tree "$w"; wait "$w" 2>/dev/null; else rc=124; fi
  return $rc
}

TMP=$(mktemp -d "${TMPDIR:-/tmp}/otel-routing-c.XXXXXX"); TMP=$(cd "$TMP" && pwd -P)
WS="$TMP/work/checkout-api"; mkdir -p "$WS" "$TMP/home" "$TMP/market"
(cd "$WS" && bash "$HERE/scaffold.sh") || { echo "scaffold failed" >&2; exit 255; }
git -C "$ROOT" archive HEAD | tar -x -C "$TMP/market"
c() { HOME="$TMP/home" COPILOT_HOME="$TMP/home/.copilot" COPILOT_GITHUB_TOKEN="$TOKEN" "$COPILOT" "$@"; }
install() { c plugin marketplace add "$TMP/market" && c plugin install otel-as-code@otel-as-code; }
with_timeout "$INSTALL_TIMEOUT" install > "$OUT/install.log" 2>&1 || {
  echo "plugin install failed or ran past ${INSTALL_TIMEOUT}s, see $OUT/install.log" >&2
  rm -rf "$TMP"; exit 255; }

ALLOW=(--allow-tool=write)
for cmd in node npm npx curl git ls cat head tail grep find sed wc jq python3 kill pkill lsof ps \
           sleep echo printf date mkdir test sort; do ALLOW+=("--allow-tool=shell($cmd:*)"); done

PLUGIN_VERSION=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' \
  "$TMP/market/.claude-plugin/plugin.json")
DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
START=$(date +%s)
( cd "$WS" && exec env HOME="$TMP/home" COPILOT_HOME="$TMP/home/.copilot" COPILOT_GITHUB_TOKEN="$TOKEN" \
    "$COPILOT" -p "$PROMPT" --model "$MODEL" --output-format json --no-auto-update --no-ask-user \
    "${ALLOW[@]}" ) > "$OUT/copilot.jsonl" 2> "$OUT/stderr.log" &
PID=$!
# Copilot has no --max-turns, so the case's cap is applied here: once the session starts a model
# turn past max_turns, it is stopped, as `claude -p --max-turns` stops the other conditions.
# Every assistant.turn_start counts, a subagent's included, so this cap is never looser.
( deadline=$(( $(date +%s) + TIMEOUT ))
  while kill -0 "$PID" 2>/dev/null; do
    turns=$(grep -c '"type": *"assistant.turn_start"' "$OUT/copilot.jsonl" 2>/dev/null)
    if [ "${turns:-0}" -gt "$MAX_TURNS" ]; then
      kill_tree "$PID"; echo "stopped at the turn cap (${MAX_TURNS})" >> "$OUT/stderr.log"; break
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      kill_tree "$PID"; echo "timed out after ${TIMEOUT}s" >> "$OUT/stderr.log"; break
    fi
    sleep 1
  done ) &
WATCH=$!
wait "$PID" 2>/dev/null; RC=$?
wait "$WATCH" 2>/dev/null
# Reaching the cap is a normal end, as it is for the other conditions, not a failed run.
grep -q '^stopped at the turn cap' "$OUT/stderr.log" && RC=0
END=$(date +%s)
PLUGIN_ROOT="$TMP/home/.copilot/installed-plugins/otel-as-code/otel-as-code"
python3 "$HERE/copilot_transcript.py" "$OUT/copilot.jsonl" "$PLUGIN_ROOT" > "$OUT/trace.jsonl"
VERSION=$("$COPILOT" --version 2>/dev/null | head -1)
python3 - "$OUT" "$CASE" "$RUN" "$RC" "$((END-START))" "$MODEL" "$VERSION" "$MAX_TURNS" \
  "$PLUGIN_VERSION" "$DATE" <<'PY'
import json, sys
out, case, run, rc, secs, model, version, max_turns, plugin_version, date = sys.argv[1:]
prem, limited, turns, net = None, [], 0, []
for line in open(f"{out}/copilot.jsonl", errors="replace"):
    try: e = json.loads(line)
    except ValueError: continue
    if e.get("type") == "result": prem = (e.get("usage") or {}).get("premiumRequests")
    if e.get("type") == "assistant.turn_start": turns += 1
    d = e.get("data") or {}
    if e.get("type") == "model.call_failure" and (d.get("statusCode") is None or d.get("statusCode") >= 500):
        net.append(str(d.get("errorMessage", ""))[:200])
    if e.get("type") == "model.call_failure" and d.get("statusCode") == 429:
        if not limited:   # kept whole: run.sh reads a reset time from it, if it carries one
            json.dump(d, open(f"{out}/refusal.json", "w"), indent=2)
        limited.append(str(d.get("errorMessage", ""))[:200])
# Copilot exits 0 after its model calls are rate limited, having done nothing; scored as is, that
# reads as a real "neither". Record it as a failed run so score.py counts it as an error.
if limited and int(rc) == 0:
    rc = "75"
    open(f"{out}/stderr.log", "a").write("rate limited (HTTP 429): " + limited[0] + "\n")
# costUsd stays null: Copilot bills premium requests, not dollars, so it is recorded on its own.
stderr = open(f"{out}/stderr.log", errors="replace").read()
capped = "stopped at the turn cap" in stderr
# A run that never got a fair model call measures the machine, not the routing: discarded too.
reason = None
if limited:
    reason = "rate limited (HTTP 429): " + limited[0]
elif turns == 0:
    reason = "the session never reached the model: " + (stderr.strip().splitlines() or ["no output"])[-1][:200]
elif net and int(rc) != 0:
    reason = "network failures before the session ended: " + net[0]
json.dump({"condition": "c", "case": case, "run": int(run), "date": date, "exitCode": int(rc),
           "durationSeconds": int(secs), "costUsd": None, "premiumRequests": prem, "model": model,
           "pluginVersion": plugin_version, "copilotVersion": version, "maxTurns": int(max_turns), "stoppedAtTurnCap": capped, "discardReason": reason},
          open(f"{out}/meta.json", "w"))
print(f"  c {case} run {run}: {prem} premium requests {secs}s exit {rc}"
      + (" RATE LIMITED" if limited else f" DISCARDED ({reason})" if reason else ""))
sys.exit(75 if reason else 0)
PY
LIMITED=$?
# A stopped session can leave Copilot's helpers writing into the temp home for a moment.
pkill -f "$TMP" 2>/dev/null || true
for _ in 1 2 3 4 5; do rm -rf "$TMP" 2>/dev/null && break; sleep 1; done
# 255 makes run.sh's xargs stop starting runs: every later run would hit the same limit.
[ "$LIMITED" -eq 75 ] && { echo "no measurement from this run; stopping the pass" >&2; exit 255; }
exit 0
