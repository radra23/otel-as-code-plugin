#!/usr/bin/env bash
# Routing eval driver (local). Costs real model calls on your account; not run in CI by default.
#
#   evals/routing/run.sh [a|b|both|c] [label]
#     a     claude plugin eval: isolated session, ONLY otel-as-code loaded
#     b     run-headless.sh: your normal user config (all your plugins), this checkout's plugin
#     c     run-copilot.sh: GitHub Copilot CLI, non-interactive, ONLY otel-as-code installed
#   env:  RUNS (default 3)  JOBS (default 3)  EVAL_MODEL (default claude-opus-5-5)
#         MAX_COST_USD (default 40, condition a ceiling)  CASE (glob, default all cases)
#         COPILOT_MODEL (default gpt-4.1)  COPILOT_BIN (default copilot)  condition c only
#         ROUTING_RESULTS (default evals/results/routing)
# Results: <ROUTING_RESULTS>/<label>-<UTC timestamp>/{a,b}/ + summary-{a,b}.json
#   Condition c instead keeps one directory per label, <ROUTING_RESULTS>/<label>/, and is
#   resumable: running it again with the same label runs only the runs still missing, and merges
#   every pass into one summary-c.json and one meta.json. It runs one session at a time and stops
#   at the first run that is no measurement (a rate-limit refusal, a failed setup step, or a
#   session that never got a fair model call), which is discarded, never scored. On macOS it
#   keeps the machine from idle-sleeping while it runs (caffeinate); a closed lid still sleeps.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; ROOT="$(cd "$HERE/../.." && pwd)"
COND=${1:-both}; LABEL=${2:-run}
RUNS=${RUNS:-3}; JOBS=${JOBS:-3}; MODEL=${EVAL_MODEL:-claude-opus-5-5}; MAX_COST=${MAX_COST_USD:-40}; CASE=${CASE:-*}
RESULTS=${ROUTING_RESULTS:-$ROOT/evals/results/routing}
if [ "$COND" = c ]; then
  OUT="$RESULTS/$LABEL"; mkdir -p "$OUT"
  echo "results: $OUT  (runs=$RUNS, one session at a time, model=${COPILOT_MODEL:-gpt-4.1}, Copilot CLI)"
else
  OUT="$RESULTS/$LABEL-$(date -u +%Y%m%dT%H%M%SZ)"; mkdir -p "$OUT"
  echo "results: $OUT  (runs=$RUNS jobs=$JOBS model=$MODEL)"
fi

run_a() {
  local A="$OUT/a"; mkdir -p "$A/traces"
  local start=$(date +%s)
  # --keep-temp so each run's trace survives for score.py; --ablation none because a
  # no-plugin arm can never route, so its delta says nothing about routing.
  (cd "$ROOT" && claude plugin eval . --tag routing --case "$CASE" --runs "$RUNS" -j "$JOBS" --ablation none \
      --scaffold --keep-temp --trust-plugin --no-publish --model "$MODEL" \
      --max-cost-usd "$MAX_COST" --output-dir "$A" \
      --allow-tools Bash Write Edit "WebFetch(domain:registry.npmjs.org)") || true
  python3 - "$A" <<'PY'
import json, os, shutil, stat, sys
a = sys.argv[1]
d = json.load(open(os.path.join(a, "aggregate-result.json")))
for c in d["cases"]:
    for n, r in enumerate(c["arms"]["with"], 1):
        tp = r.get("tracePath")
        if not tp:
            continue
        tmp = os.path.dirname(os.path.dirname(tp))
        os.chmod(tmp, 0o700)
        dst = os.path.join(a, "traces", c["name"]); os.makedirs(dst, exist_ok=True)
        if os.path.exists(tp):
            shutil.copy(tp, os.path.join(dst, f"run-{n}.jsonl"))
        for dirpath, dirnames, _ in os.walk(tmp):          # sealed/ is mode 000 by design
            for x in dirnames:
                try: os.chmod(os.path.join(dirpath, x), 0o700)
                except OSError: pass
        shutil.rmtree(tmp, ignore_errors=True)
PY
  echo "condition a wall time: $(( $(date +%s) - start ))s"
  python3 "$HERE/score.py" --eval "$A/aggregate-result.json" --traces "$A/traces" --per-run \
    --title "Condition (a): only otel-as-code loaded ($LABEL)" --json "$OUT/summary-a.json"
}

skill_usage() {  # personal skill-usage counts decide which descriptions survive the listing budget
  python3 - "$1" <<'PY'
import json, os, sys
d = json.load(open(os.path.expanduser("~/.claude.json")))
u = {k: v for k, v in d.get("skillUsage", {}).items() if k.startswith("otel-as-code:")}
json.dump(u, open(sys.argv[1], "w"), indent=2)
PY
}

run_b() {
  local B="$OUT/b"; mkdir -p "$B"
  local start=$(date +%s)
  skill_usage "$OUT/b-skill-usage-before.json"
  # Every workspace of this pass lives under one pass-owned TMPDIR. Personal SessionEnd hooks
  # (e.g. a memory plugin) can write into a workspace, or cache beside it, after run-headless.sh
  # removed it; deleting this one directory once every run has exited clears them without
  # touching anything else in the shared temp dir.
  local pass_tmp; pass_tmp=$(mktemp -d "${TMPDIR:-/tmp}/otel-routing-pass.XXXXXX")
  for c in "$HERE"/cases/$CASE/; do
    grep -q 'tags: \[routing' "$c/prompt.md" || continue
    for n in $(seq 1 "$RUNS"); do printf '%s %s %s\n' "$c" "$n" "$B"; done
  done | TMPDIR="$pass_tmp" xargs -P "$JOBS" -L 1 "$HERE/run-headless.sh" 2>/dev/null || true
  rm -rf "${pass_tmp:?}"
  skill_usage "$OUT/b-skill-usage-after.json"
  echo "condition b wall time: $(( $(date +%s) - start ))s"
  python3 "$HERE/score.py" --headless "$B" --per-run \
    --title "Condition (b): normal user config ($LABEL)" --json "$OUT/summary-b.json"
}

run_c() {
  local C="$OUT/c" P="$HERE/copilot_pass.py"; mkdir -p "$C"
  local model=${COPILOT_MODEL:-gpt-4.1} pv cv todo total remaining started stopped=finished
  pv=$(git -C "$ROOT" show HEAD:.claude-plugin/plugin.json | python3 -c 'import json,sys; print(json.load(sys.stdin)["version"])')
  cv=$("${COPILOT_BIN:-copilot}" --version 2>/dev/null | head -1)
  # Stops here, starting nothing, if the label's kept runs used another version or model.
  todo=$(python3 "$P" plan "$OUT" "$HERE/cases" "$CASE" "$RUNS" "$pv" "$cv" "$model") || return 3
  total=$(python3 "$P" total "$HERE/cases" "$CASE" "$RUNS")
  echo "condition c: $(( total - $(printf '%s' "$todo" | grep -c .) )) of $total runs already kept; plugin $pv, $cv, $model"
  started=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  # A pass the machine slept through failed every session after the sleep (network, keychain).
  command -v caffeinate >/dev/null && { caffeinate -i -w $$ & }
  local pass_tmp; pass_tmp=$(mktemp -d "${TMPDIR:-/tmp}/otel-routing-pass.XXXXXX")
  # One session at a time, read from fd 3 so a session can't swallow the rest of the list.
  while read -r dir n <&3; do
    [ -n "$dir" ] || continue
    local rd rc=0; rd="$C/$(basename "$dir")/run-$n"; rm -rf "$rd"
    TMPDIR="$pass_tmp" "$HERE/run-copilot.sh" "$dir" "$n" "$C" || rc=$?
    if [ "$rc" = 255 ]; then   # no measurement: discard it and start nothing more
      stopped=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("discardReason") or "")' \
        "$rd/meta.json" 2>/dev/null); stopped=${stopped:-a setup step failed (see the output above)}
      [ -f "$rd/refusal.json" ] && cp "$rd/refusal.json" "$OUT/last-refusal.json"
      rm -rf "$rd"; break
    fi
  done 3<<< "$todo"
  rm -rf "${pass_tmp:?}"
  remaining=$(python3 "$P" plan "$OUT" "$HERE/cases" "$CASE" "$RUNS" "$pv" "$cv" "$model" | grep -c . || true)
  python3 "$P" record "$OUT" "$started" "$stopped" "$(( total - remaining ))" "$total"
  echo "condition c: $(( total - remaining )) of $total runs done, $remaining remain"
  if [ "$stopped" != finished ]; then
    echo "stopped: $stopped. Run the same command again later to resume."
    case "$stopped" in "rate limited"*)
      if [ -f "$OUT/last-refusal.json" ]; then echo "limit reset: $(python3 "$P" reset "$OUT/last-refusal.json")"
      else echo "limit reset: the refused run left no refusal record"; fi ;;
    esac
  fi
  ls "$C"/*/run-*/meta.json >/dev/null 2>&1 || { echo "no kept runs to score yet"; return 0; }
  # score.py labels every --headless run "b"; the title and summary-c.json say which it is.
  python3 "$HERE/score.py" --headless "$C" --per-run \
    --title "Condition (c): Copilot CLI, only otel-as-code installed ($LABEL)" --json "$OUT/summary-c.json"
}

case "$COND" in
  a) run_a ;;
  b) run_b ;;
  both) run_a; run_b ;;
  c) run_c ;;
  *) echo "usage: $0 [a|b|both|c] [label]" >&2; exit 2 ;;
esac
