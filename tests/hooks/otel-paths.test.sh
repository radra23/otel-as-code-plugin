#!/usr/bin/env bash
# tests/hooks/otel-paths.test.sh
# Locks the bootstrap-vs-collector split in hooks/otel-paths.sh. This split is SAFETY-CRITICAL:
# /otel-uninstrument deletes files scoped to otel_bootstrap_globs, and the ownership marker cannot
# protect a Collector config (which carries the same marker). So if otelcol-*.yaml ever leaks back
# into otel_bootstrap_globs, /otel-uninstrument would silently rm a Collector config. These tests
# fail loudly if that regresses.
set -uo pipefail
cd "$(dirname "$0")/../.."   # repo root
# shellcheck source=hooks/otel-paths.sh
. hooks/otel-paths.sh

pass=0; fail=0
check() { if eval "$2"; then echo "PASS: $1"; pass=$((pass+1)); else echo "FAIL: $1"; fail=$((fail+1)); fi; }
has()    { otel_bootstrap_globs      | grep -qx "$1"; }
has_all(){ otel_all_generated_globs  | grep -qx "$1"; }

# --- otel_bootstrap_globs is BOOTSTRAP-ONLY (the destructive-consumer set) ---
check "bootstrap globs EXCLUDE otelcol-agent.yaml"   '! has otelcol-agent.yaml'
check "bootstrap globs EXCLUDE otelcol-gateway.yaml" '! has otelcol-gateway.yaml'
# The local stack is shared by every service; per-service /otel-uninstrument must never reach it.
check "bootstrap globs EXCLUDE otel-local.compose.yaml" '! has otel-local.compose.yaml'
check "bootstrap globs EXCLUDE otel-local.env"          '! has otel-local.env'
check "bootstrap globs include otel-java.env"        'has otel-java.env'
check "bootstrap globs include OpenTelemetry.cs"     'has OpenTelemetry.cs'
check "bootstrap globs include tracing.js"           'has tracing.js'
check "bootstrap globs include tracing.py"           'has tracing.py'
check "bootstrap globs include tracing.go"           'has tracing.go'
check "bootstrap globs include tracing.rb"           'has tracing.rb'
check "bootstrap globs include opentelemetry.rb"      'has opentelemetry.rb'

# /otel-test's telemetry test is removed with the bootstrap but is not one: /otel-instrument's
# "is there a bootstrap already?" scan reads otel_bootstrap_globs and must not find a test.
check "bootstrap globs EXCLUDE otel.test.cjs" '! has otel.test.cjs'
check "bootstrap globs EXCLUDE test_otel.py"  '! has test_otel.py'
check "test globs are exactly the two telemetry-test names" \
  '[ "$(otel_test_globs | tr "\n" " ")" = "otel.test.cjs test_otel.py " ]'

# --- otel_all_generated_globs is the UNION (read-only reporting set) ---
check "all-generated globs include the telemetry-test names" 'has_all otel.test.cjs && has_all test_otel.py'
check "all-generated globs include otelcol-agent.yaml"   'has_all otelcol-agent.yaml'
check "all-generated globs include otelcol-gateway.yaml" 'has_all otelcol-gateway.yaml'
check "all-generated globs include otel-local.compose.yaml" 'has_all otel-local.compose.yaml'
check "all-generated globs include otel-local.env"          'has_all otel-local.env'
check "all-generated globs include the bootstrap names too" 'has_all OpenTelemetry.cs && has_all tracing.js'

# --- otel_is_generated_path stays the UNION: the write-guard must still PROTECT collector
#     configs and session-summary must still REPORT them. Narrowing the delete set must not
#     narrow the guard.
check "is_generated_path still true for otelcol-agent.yaml (guard protects it)"   'otel_is_generated_path /x/otelcol-agent.yaml'
check "is_generated_path still true for otelcol-gateway.yaml (guard protects it)" 'otel_is_generated_path /x/otelcol-gateway.yaml'
check "is_generated_path true for otel-local.compose.yaml (guard protects it)" 'otel_is_generated_path /x/otel-local.compose.yaml'
check "is_generated_path true for otel-local.env (guard protects it)"          'otel_is_generated_path /x/otel-local.env'
check "is_generated_path true for the telemetry test (guard protects it)" 'otel_is_generated_path /x/otel.test.cjs && otel_is_generated_path /x/test_otel.py'
check "is_generated_path false for a test that merely resembles it" '! otel_is_generated_path /x/otel.test.js && ! otel_is_generated_path /x/test_otel_helpers.py'
check "is_generated_path false for a user's .env"                            '! otel_is_generated_path /x/.env'
check "is_generated_path true for OpenTelemetry.cs"  'otel_is_generated_path /x/OpenTelemetry.cs'
check "is_generated_path false for a hand-written file" '! otel_is_generated_path /x/server.js'

echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
