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

# Condition (c): evals/routing/copilot_transcript.py turns Copilot CLI's JSON events into the
# stream-json above, so the same score.classify decides. Event shapes as Copilot CLI 1.0.56 sent
# them (skills_loaded lists each skill's source and path; tool calls are tool.execution_start).
CROOT=/opt/copilot-home/installed-plugins/otel-as-code/otel-as-code
cskills() { python3 -c 'import json,sys; r=sys.argv[1]; print(json.dumps({"type":"session.skills_loaded","data":{"skills":[
  {"name":"otel-instrument","source":"plugin","path":r+"/commands/otel-instrument.md"},
  {"name":"customize-cloud-agent","source":"builtin","path":"/opt/copilot/builtin-skills/customize-cloud-agent/SKILL.md"},
  {"name":"add-tracing","source":"personal-agents","path":"/home/u/.agents/skills/add-tracing/SKILL.md"}]}}))' "$CROOT"; }
ctool() { python3 -c 'import json,sys; a=sys.argv[2]; print(json.dumps({"type":"tool.execution_start","data":{"toolName":sys.argv[1],"arguments":a if sys.argv[3:] else json.loads(a)}}))' "$@"; }
ctrace() { python3 evals/routing/copilot_transcript.py "$T/$1.copilot.jsonl" "$CROOT" > "$T/$1.jsonl"; }
{ cskills; ctool skill '{"skill":"otel-instrument"}'; } > "$T/c-skill.copilot.jsonl"
{ cskills; ctool skill '{"skill":"customize-cloud-agent"}'; ctool skill '{"skill":"add-tracing"}'; } > "$T/c-other-skill.copilot.jsonl"
{ cskills; ctool view "{\"path\":\"$CROOT/skills/semconv-discipline/SKILL.md\"}"; } > "$T/c-view-root.copilot.jsonl"
{ cskills; ctool task '{"agent_type":"otel-as-code:instrumentation-gen","prompt":"x"}'; } > "$T/c-agent.copilot.jsonl"
{ cskills; ctool bash '{"command":"npm install @opentelemetry/api @opentelemetry/sdk-node"}'; ctool skill '{"skill":"otel-instrument"}'; } > "$T/c-npm.copilot.jsonl"
{ cskills; ctool create '{"path":"/w/tracing.js","file_text":"require(\"@opentelemetry/sdk-node\")"}' str; } > "$T/c-create-string-args.copilot.jsonl"
{ cskills; ctool apply_patch '{"input":"*** Add File: tracing.js\n+const { NodeSDK } = require(\"@opentelemetry/sdk-node\")"}'; } > "$T/c-patch.copilot.jsonl"
{ cskills; ctool edit '{"path":"/w/lib/orders.js","old_str":"floor","new_str":"round"}'; ctool web_fetch '{"url":"https://opentelemetry.io"}'; } > "$T/c-neither.copilot.jsonl"
for c in c-skill c-other-skill c-view-root c-agent c-npm c-create-string-args c-patch c-neither; do ctrace "$c"; done
check c-skill routed
check c-other-skill neither
check c-view-root routed
check c-agent routed
check c-npm hand-rolled
check c-create-string-args hand-rolled
check c-patch hand-rolled
check c-neither neither
if grep -q '"x-unmapped", "name": "web_fetch"' "$T/c-neither.jsonl"; then echo "PASS c-neither keeps web_fetch as unmapped"; else echo "FAIL c-neither: web_fetch not recorded as unmapped"; fail=1; fi

# The adapter on two real Copilot CLI 1.0.56 transcripts (gpt-4.1), scrubbed by
# evals/routing/scrub_copilot.py: a routed run of "add OpenTelemetry to this service" (first call:
# the plugin's otel-instrument skill) and a run of "explain what a span is" that answers in text.
FROOT=/work/otel-routing-c/home/.copilot/installed-plugins/otel-as-code/otel-as-code
for pair in "copilot-routed.add-opentelemetry:routed" "copilot-not-routed.explain-span:neither"; do
  f=${pair%%:*}; want=${pair#*:}
  python3 evals/routing/copilot_transcript.py "evals/routing/fixtures/$f.jsonl" "$FROOT" > "$T/$f.jsonl"
  check "$f" "$want"
done
got=$(python3 -c 'import sys; sys.path.insert(0,"evals/routing"); import score; print(",".join(score.classify(sys.argv[1])[1]))' "$T/copilot-routed.add-opentelemetry.jsonl")
if [ "$got" = otel-instrument ]; then echo "PASS the captured routed run picked otel-instrument"; else echo "FAIL captured routed run skills: $got"; fail=1; fi

# run-copilot.sh end to end against a stub `copilot` (no model calls): a session whose model
# calls were rate limited must be recorded as a failed run and stop the pass (exit 255), never
# scored as a real "neither"; a clean session that calls the plugin's skill scores routed.
STUB="$T/copilot-stub"
cat > "$STUB" <<'SH'
#!/usr/bin/env bash
[ "$1" = plugin ] && exit 0
root="$COPILOT_HOME/installed-plugins/otel-as-code/otel-as-code"
printf '{"type":"session.skills_loaded","data":{"skills":[{"name":"otel-instrument","source":"plugin","path":"%s/commands/otel-instrument.md"}]}}\n' "$root"
if [ "$STUB_MODE" = endless ]; then
  for i in $(seq 0 11); do printf '{"type":"assistant.turn_start","data":{"turnId":"%s"}}\n' "$i"; done
  sleep 60; exit 0
elif [ "$STUB_MODE" = limited ]; then
  printf '{"type":"model.call_failure","data":{"model":"gpt-4.1","statusCode":429,"errorMessage":"rate limit for utility models"}}\n'
else
  printf '{"type":"tool.execution_start","data":{"toolName":"skill","arguments":{"skill":"otel-instrument"}}}\n'
fi
printf '{"type":"result","exitCode":0,"usage":{"premiumRequests":0}}\n'
SH
chmod +x "$STUB"
for mode in limited clean endless; do
  rc=0
  STUB_MODE=$mode COPILOT_BIN="$STUB" COPILOT_GITHUB_TOKEN=stub TMPDIR="$T" \
    bash evals/routing/run-copilot.sh evals/routing/cases/add-tracing 1 "$T/c-$mode" >/dev/null 2>&1 || rc=$?
  echo "$rc" > "$T/c-$mode.rc"
done
got=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["exitCode"])' "$T/c-limited/add-tracing/run-1/meta.json" 2>/dev/null || echo none)
if [ "$(cat "$T/c-limited.rc")" = 255 ] && [ "$got" = 75 ]; then echo "PASS run-copilot flags a rate-limited run and stops the pass"
else echo "FAIL run-copilot rate limit: runner exit $(cat "$T/c-limited.rc"), recorded exitCode $got"; fail=1; fi
got=$(python3 -c 'import sys; sys.path.insert(0,"evals/routing"); import score; print(score.load_b(sys.argv[1], score.case_expectations("evals/routing/cases"))[0]["verdict"])' "$T/c-clean" 2>/dev/null || echo none)
if [ "$(cat "$T/c-clean.rc")" = 0 ] && [ "$got" = routed ]; then echo "PASS run-copilot scores a clean skill call as routed"
else echo "FAIL run-copilot clean run: runner exit $(cat "$T/c-clean.rc"), verdict $got"; fail=1; fi
# The case's max_turns (8 for add-tracing) stops a session that keeps going: well before the
# stub's 60 s, recorded as capped, and not as a failed run.
got=$(python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); print(m["stoppedAtTurnCap"], m["exitCode"], m["maxTurns"], m["durationSeconds"] < 30)' "$T/c-endless/add-tracing/run-1/meta.json" 2>/dev/null || echo none)
if [ "$got" = "True 0 8 True" ]; then echo "PASS run-copilot stops a session at the case's turn cap"
else echo "FAIL run-copilot turn cap: got $got"; fail=1; fi

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
sys.exit(1 if bad or len(exp) != 14 or pos != 10 else 0)
PY
exit $fail
