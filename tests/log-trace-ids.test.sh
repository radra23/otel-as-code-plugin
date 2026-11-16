#!/usr/bin/env bash
# tests/log-trace-ids.test.sh: offline checks for trace IDs in log lines (#279).
# The Python block must be the same text in both goldens and in the generator's template, the
# maturity matrix must have a row per language, and the Node.js golden must not switch off the
# instrumentations that do the work there. Behaviour is proven by tests/e2e/log-trace-ids.sh.
set -uo pipefail
cd "$(dirname "$0")/.."
pass=0; fail=0
check() { if eval "$2"; then echo "PASS: $1"; pass=$((pass+1)); else echo "FAIL: $1"; fail=$((fail+1)); fi; }

# block <file>: from the section comment to the call, inclusive.
block() { awk '/^# --- Trace IDs in log lines/{on=1} on{print} on&&/^_add_trace_ids_to_logs\(\)$/{exit}' "$1"; }
G=tests/snapshots/instrument/python/tracing.py
check "the default Python golden has the block, ending in its call" \
  '[ "$(block $G | tail -1)" = "_add_trace_ids_to_logs()" ] && [ "$(block $G | wc -l)" -gt 30 ]'
check "the --experimental golden has the same block" \
  '[ "$(block $G)" = "$(block tests/snapshots/instrument/python/tracing.experimental.py)" ]'
check "the generator's template has the same block" \
  '[ "$(block $G)" = "$(block agents/instrumentation-gen.md)" ]'
check "the block compiles and both goldens still do" \
  'python3 -m py_compile $G tests/snapshots/instrument/python/tracing.experimental.py'
check "the block never sets a log format or calls basicConfig" \
  '! block $G | grep -v "^#" | grep -q "basicConfig\|set_logging_format\|setFormatter"'
check "text is appended only for the stock formatter class, and never to JSON" \
  'block $G | grep -q "type(self) is logging.Formatter" && block $G | grep -qF "startswith((\"{\", \"[\"))"'
check "the record fields are the upstream names, not trace_id (which would collide with extra=)" \
  'block $G | grep -q "record.otelTraceID = " && ! block $G | grep -q "record.trace_id"'
check "no new Python requirement came with it" \
  '! grep -qi "instrumentation-logging" tests/snapshots/instrument/python/requirements.txt'

N=tests/snapshots/instrument/nodejs/tracing.js
check "the Node.js goldens do not disable the pino, winston or bunyan instrumentations" \
  '! grep -q "instrumentation-\(pino\|winston\|bunyan\)" $N tests/snapshots/instrument/nodejs/tracing.experimental.js'

M=skills/language-maturity/SKILL.md
for lang in "Node.js" "Python" "Java" ".NET" "Go" "Rust" "PHP" "Ruby"; do
  check "the maturity matrix has a log-line row for $lang" \
    'awk "/^## Trace IDs in log lines/{on=1;next} on&&/^## /{exit} on" $M | grep -q "^| $lang  *|"'
done
check "only the two languages the e2e runs are marked as checked" \
  '[ "$(awk "/^## Trace IDs in log lines/{on=1;next} on&&/^## /{exit} on" $M | grep -c "| yes |$")" = 2 ] && [ "$(awk "/^## Trace IDs in log lines/{on=1;next} on&&/^## /{exit} on" $M | grep -c "| not checked |$")" = 6 ]'
check "the generator points at that section" 'grep -q "Trace IDs in log lines" agents/instrumentation-gen.md'
check "the e2e is wired into CI" 'grep -q "bash tests/e2e/log-trace-ids.sh" .github/workflows/ci.yml'

echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
