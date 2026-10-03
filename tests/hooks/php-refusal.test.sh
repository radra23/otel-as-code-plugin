#!/usr/bin/env bash
# tests/hooks/php-refusal.test.sh
# php is in the scanner's language enum but has no generator yet (#117). This pins today's
# refusal end to end: the scanner sets generatorSupported:false with a reason that names the
# language and issue, inScope stays true, /otel-instrument refuses without calling the service a
# browser bundle, and the fixture is the first shape the design proposal targets (Laravel). When
# the generator lands, the fixture flips to supported and this test is the one to update.
# (Rust shared this test until #118 shipped its generator; see rust-instrument-wiring.test.sh.)
set -uo pipefail
cd "$(dirname "$0")/../.."
pass=0; fail=0
check() { if eval "$2"; then echo "PASS: $1"; pass=$((pass+1)); else echo "FAIL: $1"; fail=$((fail+1)); fi; }

SCANNER="agents/repo-context-scanner.md"
INSTR="commands/otel-instrument.md"
INIT="commands/otel-init.md"
PHP="fixtures/php-laravel-app"

# --- scanner: detected, in scope, not supported, with a reason naming the issue ---
check "scanner detects php by composer.json" \
  'grep -qE "\| \`php\` +\| \`composer.json\`" "$SCANNER"'
check "scanner: php is always generatorSupported:false, inScope:true" \
  'grep -q "For \`php\` it is always \`false\`" "$SCANNER" && grep -q "stays$" "$SCANNER" && grep -q "^     \`inScope: true\`" "$SCANNER"'
check "scanner: the refusal reason names the language and its issue" \
  'grep -q "no php generator yet (#117)" "$SCANNER"'

# --- /otel-instrument: refuses with the reason, never with the browser explanation ---
check "instrument refusal prints the reason and adds nothing generic" \
  'grep -q "The reason carries the explanation, so print it as given" "$INSTR"'
check "instrument: the browser sentence is limited to runtime browser" \
  'grep -q "Only for$" "$INSTR" && grep -q "must not be told it is a browser bundle" "$INSTR"'
check "instrument: language backstop still names php as coming in v1" \
  'grep -q "v1 will add: php." "$INSTR"'

# --- fixture: the first shape the proposal would support, and no OTel yet ---
check "php fixture is a Laravel app (composer.json requires laravel/framework)" \
  'grep -q "\"laravel/framework\"" "$PHP/composer.json" && test -f "$PHP/artisan" && test -f "$PHP/routes/web.php"'
check "php fixture stays greenfield (no OTel)" \
  '! grep -rqiE "opentelemetry|open-telemetry" "$PHP"'

# --- freshness: the manifest is an identity input, so the service never reads as always stale ---
check "the /otel-init identity regex covers composer.json" \
  'grep -q "composer\\\\.json" "$INIT"'

echo ""
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
