#!/usr/bin/env bash
# tests/fastapi-native.test.sh: offline checks for FastAPI's own telemetry (#300).
# instrument_fastapi() and the check it rests on must be the same text in both Python goldens and
# in the generator's template. Behaviour is proven by tests/e2e/fastapi-native.sh.
set -uo pipefail
cd "$(dirname "$0")/.."
pass=0; fail=0
check() { if eval "$2"; then echo "PASS: $1"; pass=$((pass+1)); else echo "FAIL: $1"; fail=$((fail+1)); fi; }
# block <file>: from the check's definition to the end of instrument_fastapi().
block() { awk '/^def _fastapi_traces_itself\(\):$/{on=1} on{print} on&&/^    return app$/{exit}' "$1"; }
G=tests/snapshots/instrument/python/tracing.py
check "the default Python golden has the check and instrument_fastapi()" \
  '[ "$(block $G | tail -1)" = "    return app" ] && block $G | grep -q "^def instrument_fastapi(app):$"'
check "the --experimental golden has the same text" \
  '[ "$(block $G)" = "$(block tests/snapshots/instrument/python/tracing.experimental.py)" ]'
check "the generator's template has the same text" '[ "$(block $G)" = "$(block agents/instrumentation-gen.md)" ]'
check "the package is called only where FastAPI has no telemetry of its own" \
  'block $G | grep -A2 "if not _fastapi_traces_itself():" | grep -q "FastAPIInstrumentor.instrument_app(app)"'
check "the decision is made from what is installed, not from a version string" \
  'block $G | grep -q "import fastapi.telemetry" && ! block $G | grep -q "__version__"'
check "the shutdown flush is wired on both paths" \
  'block $G | grep -q "^    _flush_on_app_shutdown(app)$"'
check "there is a way back to the package" 'block $G | grep -q "OTEL_AS_CODE_FASTAPI_SOURCE"'
check "the package stays in the requirements, for older FastAPI" \
  'grep -q "^opentelemetry-instrumentation-fastapi" tests/snapshots/instrument/python/requirements.txt'
check "the generator is told to say a regeneration changes the names on the wire" \
  'grep -q "changes what an existing" agents/instrumentation-gen.md'
check "the e2e is wired into CI" 'grep -q "bash tests/e2e/fastapi-native.sh" .github/workflows/ci.yml'
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
