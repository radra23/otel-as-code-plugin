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
check "only the six languages the e2e runs are marked as checked" \
  '[ "$(awk "/^## Trace IDs in log lines/{on=1;next} on&&/^## /{exit} on" $M | grep -c "| yes |$")" = 6 ] && [ "$(awk "/^## Trace IDs in log lines/{on=1;next} on&&/^## /{exit} on" $M | grep -c "| not checked |$")" = 2 ]'

# Java: the generator prints, never writes. The e2e reads these two lines out of the generator, so
# each must appear exactly once, and the agent pin the e2e downloads must be the generator's.
GEN=agents/instrumentation-gen.md
check "java: the generator has exactly one pattern-token line, naming both MDC keys" \
  '[ "$(grep -c "^Logback or Log4j 2 pattern, before %n: trace_id=%X{trace_id} span_id=%X{span_id}$" $GEN)" = 1 ]'
check "java: the generator has exactly one Spring Boot property line, keeping the level" \
  '[ "$(grep -c "^Spring Boot application.properties: logging.pattern.level=.*%mdc{trace_id}.* %5p$" $GEN)" = 1 ]'
check "java: the generator says never to edit the app's logging config" \
  'grep -q "never edit \`logback.xml\`, \`log4j2.xml\`" $GEN'
check "java: the e2e reads both lines and the agent pin from the generator" \
  'grep -qF "gen_line '"'"'Logback or Log4j 2 pattern, before %n: '"'"'" tests/e2e/log-trace-ids.sh && grep -qF "gen_line '"'"'Spring Boot application.properties: '"'"'" tests/e2e/log-trace-ids.sh && grep -qF "s/^OTEL_JAVA_AGENT_VERSION = //p" tests/e2e/log-trace-ids.sh'
check "java: the golden env file is still the only Java file generated (no logging config)" \
  '[ "$(git ls-files tests/snapshots/instrument/java)" = "tests/snapshots/instrument/java/otel-java.env" ]'

# .NET: the same posture. One printed appsettings fragment, which names the formatter (without a
# FormatterName the console logger ignores FormatterOptions) and is valid JSON once wrapped.
DN='.NET appsettings.json, inside the top-level object: '
check ".NET: the generator has exactly one appsettings line" \
  '[ "$(grep -c "^$DN" $GEN)" = 1 ]'
check ".NET: the fragment names the formatter and turns FormatterOptions.IncludeScopes on" \
  'sed -n "s/^$DN//p" $GEN | python3 -c "import json,sys; c=json.loads(\"{\"+sys.stdin.read()+\"}\")[\"Logging\"][\"Console\"]; sys.exit(0 if c[\"FormatterName\"]==\"simple\" and c[\"FormatterOptions\"][\"IncludeScopes\"] is True else 1)"'
check ".NET: the generator says never to edit appsettings.json" \
  'grep -q "appsettings.json\` belongs to the app: never edit it" $GEN'
check ".NET: the e2e reads the fragment from the generator" \
  'grep -qF "gen_line '"'"'.NET appsettings.json, inside the top-level object: '"'"'" tests/e2e/log-trace-ids.sh'
GO=tests/snapshots/instrument/go/tracing.go
GOLINE='slog.SetDefault(slog.New(WithTraceIDs(slog.NewTextHandler(os.Stderr, nil))))'
check "go: the golden defines WithTraceIDs and its handler forwards WithAttrs and WithGroup" \
  'grep -qF "func WithTraceIDs(h slog.Handler) slog.Handler" $GO && grep -qF "func (t traceIDHandler) WithAttrs(" $GO && grep -qF "func (t traceIDHandler) WithGroup(" $GO'
check "go: it adds attributes on a clone, only for a valid span context" \
  'grep -A4 "func (t traceIDHandler) Handle(" $GO | grep -qF "sc.IsValid()" && grep -A4 "func (t traceIDHandler) Handle(" $GO | grep -qF "r = r.Clone()"'
check "go: the generator's template carries the same WithTraceIDs code as the golden" \
  'blk() { awk "/^\/\/ WithTraceIDs wraps/{on=1} on{print} on&&/^func \(t traceIDHandler\) WithGroup/{getline; print; getline; print; exit}" "$1"; }; [ -n "$(blk $GO)" ] && [ "$(blk $GO)" = "$(blk $GEN)" ]'
check "go: the generator prints exactly one WithTraceIDs line, and the e2e reads that line" \
  '[ "$(grep -cxF "$GOLINE" $GEN)" = 1 ] && grep -qF "$GOLINE" tests/e2e/log-trace-ids.sh'
check "go: the bootstrap still never sets the default logger itself" '! grep -q "slog.SetDefault" $GO'

RB=tests/snapshots/instrument/ruby/tracing.rb
rbmod() { awk '/^# Trace IDs in the application.s own log lines/{on=1} on{print} on&&/^end$/{exit}' "$1"; }
check "ruby: the golden defines OtelAsCode.add_trace_ids and trace_log_tag" \
  'rbmod $RB | grep -qF "def self.add_trace_ids(logger)" && rbmod $RB | grep -qF "def self.trace_log_tag"'
check "ruby: the generator's template carries the same module as the golden" \
  '[ -n "$(rbmod $RB)" ] && [ "$(rbmod $RB)" = "$(rbmod $GEN)" ]'
check "ruby: the tag is nil outside a valid span, and JSON lines get nothing appended" \
  'rbmod $RB | grep -qF "if span.valid?" && rbmod $RB | grep -qF "start_with?('"'"'{'"'"', '"'"'['"'"')"'
check "ruby: the golden is valid Ruby" 'ruby -c $RB >/dev/null'
check "ruby: the generator prints each line exactly once, and the e2e reads both" \
  '[ "$(grep -cxF "  OtelAsCode.add_trace_ids(logger)" $GEN)" = 1 ] && [ "$(grep -cxF "  config.log_tags = [:request_id, ->(_req) { OtelAsCode.trace_log_tag }]" $GEN)" = 1 ] && grep -qF "rb_line '"'"'OtelAsCode.add_trace_ids(logger)'"'"'" tests/e2e/log-trace-ids.sh && grep -qF "rb_line '"'"'config.log_tags = [:request_id, ->(_req) { OtelAsCode.trace_log_tag }]'"'"'" tests/e2e/log-trace-ids.sh'

check ".NET: OpenTelemetry.cs and the csproj are still the only .NET goldens (no appsettings)" \
  '[ "$(git ls-files tests/snapshots/instrument/dotnet | grep -v /.gitignore$ | xargs -n1 basename | tr "\n" " ")" = "OpenTelemetry.cs checkout-api.csproj " ]'
check "the generator points at that section" 'grep -q "Trace IDs in log lines" agents/instrumentation-gen.md'
check "the e2e is wired into CI" 'grep -q "bash tests/e2e/log-trace-ids.sh" .github/workflows/ci.yml'

echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
