#!/usr/bin/env bash
# Offline tests for evals/routing/score.py: the rules that decide "routed" vs "hand-rolled".
# No model calls. Synthetic stream-json traces, one per rule, plus the edge cases that would
# let a loosened scorer pass (a plugin read AFTER hand-rolling must still score hand-rolled).
set -euo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
ROOT=/opt/plugins/otel-as-code
init() { printf '{"type":"system","subtype":"init","plugins":[{"name":"otel-as-code","path":"%s"}]}\n' "$ROOT"; }
tool() { python3 -c 'import json,sys; print(json.dumps({"type":"assistant","message":{"content":[{"type":"tool_use","name":sys.argv[1],"input":json.loads(sys.argv[2])}]}}))' "$1" "$2"; }

{ init; tool Skill '{"skill":"otel-as-code:otel-instrument"}'; tool Write '{"file_path":"tracing.js","content":"require(\"@opentelemetry/sdk-node\")"}'; } > "$T/skill.jsonl"
{ init; tool Read "{\"file_path\":\"$ROOT/commands/otel-init.md\"}"; } > "$T/read-root.jsonl"
{ init; tool Read '{"file_path":"/home/u/.claude/plugins/cache/otel-as-code/otel-as-code/0.9.7/skills/semconv-discipline/SKILL.md"}'; } > "$T/read-cache.jsonl"
{ init; tool Agent '{"subagent_type":"otel-as-code:instrumentation-gen","prompt":"x"}'; } > "$T/agent.jsonl"
{ init; tool Bash "{\"command\":\"bash $ROOT/hooks/semconv-lint.sh\"}"; } > "$T/bash-root.jsonl"
{ init; tool Bash '{"command":"npm install --save @opentelemetry/api @opentelemetry/sdk-node"}'; } > "$T/npm.jsonl"
{ init; tool Write '{"file_path":"tracing.js","content":"const { NodeSDK } = require(\"@opentelemetry/sdk-node\")"}'; tool Skill '{"skill":"otel-as-code:semconv-discipline"}'; } > "$T/late-route.jsonl"
{ init; tool Edit '{"file_path":"lib/orders.js","old_string":"floor","new_string":"round"}'; } > "$T/neither.jsonl"
{ init; tool Skill '{"skill":"superpowers:systematic-debugging"}'; tool Read '{"file_path":"/work/lib/orders.js"}'; } > "$T/other-skill.jsonl"
{ init; tool Read "{\"file_path\":\"${ROOT}-fork/commands/x.md\"}"; } > "$T/sibling-dir.jsonl"
# Regression: a Grep regex and relative paths must never resolve against the scorer's own cwd.
# The baseline scored "explain what a span is" as routed because score.py ran inside the repo.
printf '{"type":"system","subtype":"init","plugins":[{"name":"otel-as-code","path":"%s"}]}\n' "$PWD" > "$T/rel.jsonl"
{ cat "$T/rel.jsonl"; tool Grep '{"pattern":"span|tracer|opentelemetry"}'; tool Grep '{"pattern":"orderTotal","path":"lib"}'; tool Read '{"file_path":"commands/otel-init.md"}'; tool Glob '{"pattern":"skills/*/SKILL.md"}'; } > "$T/relative.jsonl"
{ cat "$T/rel.jsonl"; tool Glob "{\"pattern\":\"$PWD/skills/*/SKILL.md\"}"; } > "$T/abs-glob.jsonl"

fail=0
check() {
  got=$(python3 -c 'import sys; sys.path.insert(0,"evals/routing"); import score; print(score.classify(sys.argv[1])[0])' "$T/$1.jsonl")
  if [ "$got" = "$2" ]; then echo "PASS $1 -> $got"; else echo "FAIL $1: expected $2, got $got"; fail=1; fi
}
check skill routed
check read-root routed
check read-cache routed
check agent routed
check bash-root routed
check npm hand-rolled
check late-route hand-rolled
check neither neither
check other-skill neither
check sibling-dir neither
check relative neither
check abs-glob routed

# Every case directory carries a prompt, a should-/should-not-route tag, a grader and a scaffold.
python3 - <<'PY' || fail=1
import glob, os, sys
sys.path.insert(0, "evals/routing")
import score
exp = score.case_expectations("evals/routing/cases")
bad = [c for c in glob.glob("evals/routing/cases/*/")
       if not (glob.glob(c + "graders/*.md") and os.path.exists(c + "scaffold.sh") and os.path.exists(c + "case.yaml"))]
pos = sum(v["expect"] == "should-route" for v in exp.values())
print(f"cases: {len(exp)} ({pos} should-route, {len(exp) - pos} should-not-route); incomplete: {bad or 'none'}")
sys.exit(1 if bad or len(exp) != 12 or pos != 8 else 0)
PY
exit $fail
