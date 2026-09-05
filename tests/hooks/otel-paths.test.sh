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
check "bootstrap globs include otel-java.env"        'has otel-java.env'
check "bootstrap globs include OpenTelemetry.cs"     'has OpenTelemetry.cs'
check "bootstrap globs include tracing.js"           'has tracing.js'
check "bootstrap globs include tracing.py"           'has tracing.py'
check "bootstrap globs include tracing.go"           'has tracing.go'
check "bootstrap globs include tracing.rb"           'has tracing.rb'
check "bootstrap globs include opentelemetry.rb"      'has opentelemetry.rb'

# --- otel_all_generated_globs is the UNION (read-only reporting set) ---
check "all-generated globs include otelcol-agent.yaml"   'has_all otelcol-agent.yaml'
check "all-generated globs include otelcol-gateway.yaml" 'has_all otelcol-gateway.yaml'
check "all-generated globs include the bootstrap names too" 'has_all OpenTelemetry.cs && has_all tracing.js'

# --- otel_is_generated_path stays the UNION: the write-guard must still PROTECT collector
#     configs and session-summary must still REPORT them. Narrowing the delete set must not
#     narrow the guard.
check "is_generated_path still true for otelcol-agent.yaml (guard protects it)"   'otel_is_generated_path /x/otelcol-agent.yaml'
check "is_generated_path still true for otelcol-gateway.yaml (guard protects it)" 'otel_is_generated_path /x/otelcol-gateway.yaml'
check "is_generated_path true for OpenTelemetry.cs"  'otel_is_generated_path /x/OpenTelemetry.cs'
check "is_generated_path false for a hand-written file" '! otel_is_generated_path /x/server.js'

echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
