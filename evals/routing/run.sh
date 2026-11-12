#!/usr/bin/env bash
# Routing eval driver (local). Costs real model calls on your account; not run in CI by default.
#
#   evals/routing/run.sh [a|b|both] [label]
#     a     claude plugin eval: isolated session, ONLY otel-as-code loaded
#     b     run-headless.sh: your normal user config (all your plugins), this checkout's plugin
#   env:  RUNS (default 3)  JOBS (default 3)  EVAL_MODEL (default claude-opus-5-5)
#         MAX_COST_USD (default 40, condition a ceiling)  CASE (glob, default all cases)
# Results: evals/results/routing/<label>-<UTC timestamp>/{a,b}/ + summary-{a,b}.json
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; ROOT="$(cd "$HERE/../.." && pwd)"
COND=${1:-both}; LABEL=${2:-run}
RUNS=${RUNS:-3}; JOBS=${JOBS:-3}; MODEL=${EVAL_MODEL:-claude-opus-5-5}; MAX_COST=${MAX_COST_USD:-40}; CASE=${CASE:-*}
OUT="$ROOT/evals/results/routing/$LABEL-$(date -u +%Y%m%dT%H%M%SZ)"; mkdir -p "$OUT"
echo "results: $OUT  (runs=$RUNS jobs=$JOBS model=$MODEL)"

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
  for c in "$HERE"/cases/$CASE/; do
    grep -q 'tags: \[routing' "$c/prompt.md" || continue
    for n in $(seq 1 "$RUNS"); do printf '%s %s %s\n' "$c" "$n" "$B"; done
  done | xargs -P "$JOBS" -L 1 "$HERE/run-headless.sh" 2>/dev/null || true
  # Personal SessionEnd hooks (e.g. a memory plugin) can write into a workspace after
  # run-headless.sh removed it, recreating it; sweep once every run of this pass has exited.
  local tmp="${TMPDIR:-/tmp}"
  rm -rf "${tmp:?}"/otel-routing-b.* "${tmp:?}"/*otel-routing-b-* 2>/dev/null || true
  skill_usage "$OUT/b-skill-usage-after.json"
  echo "condition b wall time: $(( $(date +%s) - start ))s"
  python3 "$HERE/score.py" --headless "$B" --per-run \
    --title "Condition (b): normal user config ($LABEL)" --json "$OUT/summary-b.json"
}

case "$COND" in
  a) run_a ;;
  b) run_b ;;
  both) run_a; run_b ;;
  *) echo "usage: $0 [a|b|both] [label]" >&2; exit 2 ;;
esac
