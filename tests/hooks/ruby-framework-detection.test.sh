#!/usr/bin/env bash
# tests/hooks/ruby-framework-detection.test.sh
# Locks the Rails-vs-non-Rails PLACEMENT detection added to agents/repo-context-scanner.md
# (#116): Rails evidence -> framework:rails (drives the initializer placement in
# instrumentation-gen.md's Ruby section); non-Rails evidence -> framework stays other/unknown
# (drives the generic tracing.rb + printed-line placement). Unlike Go's gate, nothing is ever
# REFUSED here — this test is about which placement decision gets made, not generatorSupported.
set -uo pipefail
cd "$(dirname "$0")/../.."
pass=0; fail=0
check() { if eval "$2"; then echo "PASS: $1"; pass=$((pass+1)); else echo "FAIL: $1"; fail=$((fail+1)); fi; }

SCANNER="agents/repo-context-scanner.md"
RAILS="fixtures/ruby-rails-app"
SINATRA="fixtures/ruby-greenfield"

# --- Rails detected -> initializer placement ---
check "scanner names Gemfile requiring rails as evidence" \
  'grep -qE "Gemfile.{0,20}requiring.{0,10}rails" "$SCANNER"'
check "scanner names config/application.rb as evidence" \
  'grep -q "config/application.rb" "$SCANNER"'
check "ruby-rails-app fixture Gemfile requires rails (repro intact)" \
  'grep -q "gem .rails." "$RAILS/Gemfile"'
check "ruby-rails-app fixture has config/application.rb (repro intact)" \
  'test -f "$RAILS/config/application.rb"'
check "scanner cross-references the Ruby placement section in instrumentation-gen.md" \
  'grep -q "Ruby section in \`agents/instrumentation-gen.md\`" "$SCANNER"'

# --- non-Rails (Sinatra) -> generic tracing.rb + printed line placement ---
check "ruby-greenfield fixture Gemfile does NOT require rails" \
  '! grep -q "gem .rails." "$SINATRA/Gemfile"'
check "ruby-greenfield fixture has no config/application.rb" \
  '! test -f "$SINATRA/config/application.rb"'
check "ruby-greenfield fixture's wiring line comes AFTER the sinatra/json requires" \
  'grep -n "require" "$SINATRA/app.rb" | head -3 | tail -1 | grep -q "require_relative .tracing."'

echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
