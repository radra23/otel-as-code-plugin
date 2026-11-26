#!/usr/bin/env bash
# tests/hooks/ruby-instrument-wiring.test.sh
# Locks Ruby's wiring into commands/otel-instrument.md and agents/instrumentation-gen.md (#116):
# the command must recognize the language and know its verification command; the generator must
# actually define what the command's summary promises.
set -uo pipefail
cd "$(dirname "$0")/../.."
source tests/hooks/lib/supported-languages.sh   # supported_languages, read by meaning (#259)
pass=0; fail=0
check() { if eval "$2"; then echo "PASS: $1"; pass=$((pass+1)); else echo "FAIL: $1"; fail=$((fail+1)); fi; }

CMD="commands/otel-instrument.md"
GEN="agents/instrumentation-gen.md"

check "otel-instrument recognizes ruby as a supported language" \
  'supported_languages | grep -qx ruby'
check "otel-instrument documents the bundle exec ruby smoke check" \
  'grep -qF "bundle exec ruby -e" "$CMD"'
check "otel-instrument notes Ruby exports over OTLP/HTTP :4318, not the usual :4317" \
  'grep -qF ":4318" "$CMD"'
check "instrumentation-gen defines the Ruby section the command summary promises" \
  'grep -q "## Ruby (opentelemetry-instrumentation-all)" "$GEN"'
check "instrumentation-gen's Ruby section prints bundle install as the required follow-up" \
  'grep -qF "bundle install" "$GEN"'

echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
