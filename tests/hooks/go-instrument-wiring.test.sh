#!/usr/bin/env bash
# tests/hooks/go-instrument-wiring.test.sh
# Locks Go's wiring into commands/otel-instrument.md and agents/instrumentation-gen.md (#115):
# the command must recognize the language and know its build-verification command; the generator
# must actually define what the command's summary text promises.
set -uo pipefail
cd "$(dirname "$0")/../.."
pass=0; fail=0
check() { if eval "$2"; then echo "PASS: $1"; pass=$((pass+1)); else echo "FAIL: $1"; fail=$((fail+1)); fi; }

CMD="commands/otel-instrument.md"
GEN="agents/instrumentation-gen.md"

check "otel-instrument recognizes go as a supported language" \
  'grep -qE "nodejs.{0,20}python.{0,20}java.{0,20}dotnet.{0,20}(or )?go" "$CMD"'
check "otel-instrument documents go build ./... as the smoke check" \
  'grep -qF "go build ./..." "$CMD"'
check "otel-instrument groups go with the exports-nowhere-until-configured languages" \
  'grep -qE "Node\.js/Python/Go|Node\.js, Python, and Go" "$CMD"'
check "instrumentation-gen defines the Go section the command's summary promises" \
  'grep -q "## Go (manual SDK wiring)" "$GEN"'
check "instrumentation-gen's Go section prints go mod tidy as the required follow-up" \
  'grep -qF "go mod tidy" "$GEN"'

echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
