#!/usr/bin/env bash
# tests/hooks/php-rust-refusal.test.sh
# php and rust are in the scanner's language enum but have no generator yet (#117, #118). This
# pins today's refusal end to end: the scanner sets generatorSupported:false with a reason that
# names the language and issue, inScope stays true, /otel-instrument refuses without calling the
# service a browser bundle, and each fixture is the first shape its design proposal targets
# (Laravel, axum). When a generator lands, these fixtures flip to supported and this test is the
# one to update.
set -uo pipefail
cd "$(dirname "$0")/../.."
pass=0; fail=0
check() { if eval "$2"; then echo "PASS: $1"; pass=$((pass+1)); else echo "FAIL: $1"; fail=$((fail+1)); fi; }

SCANNER="agents/repo-context-scanner.md"
INSTR="commands/otel-instrument.md"
INIT="commands/otel-init.md"
PHP="fixtures/php-laravel-app"
RUST="fixtures/rust-axum-app"

# --- scanner: detected, in scope, not supported, with a reason naming the issue ---
check "scanner detects php by composer.json and rust by Cargo.toml" \
  'grep -qE "\| \`php\` +\| \`composer.json\`" "$SCANNER" && grep -qE "\| \`rust\` +\| \`Cargo.toml\`" "$SCANNER"'
check "scanner: php and rust are always generatorSupported:false, inScope:true" \
  'grep -q "For \`php\` and \`rust\` it is always \`false\`" "$SCANNER" && grep -q "stays \`inScope: true\`" "$SCANNER"'
check "scanner: the refusal reason names the language and its issue" \
  'grep -q "no php generator yet (#117)" "$SCANNER" && grep -q "likewise \`rust\`, #118" "$SCANNER"'

# --- /otel-instrument: refuses with the reason, never with the browser explanation ---
check "instrument refusal prints the reason and adds nothing generic" \
  'grep -q "The reason carries the explanation, so print it as given" "$INSTR"'
check "instrument: the browser sentence is limited to runtime browser" \
  'grep -q "Only for$" "$INSTR" && grep -q "must not be told it is a browser bundle" "$INSTR"'
check "instrument: language backstop still names php and rust as coming in v1" \
  'grep -q "v1 will add: php, rust." "$INSTR"'

# --- fixtures: the first shape each proposal would support, and no OTel yet ---
check "php fixture is a Laravel app (composer.json requires laravel/framework)" \
  'grep -q "\"laravel/framework\"" "$PHP/composer.json" && test -f "$PHP/artisan" && test -f "$PHP/routes/web.php"'
check "rust fixture is an axum 0.8 binary (Cargo.toml + src/main.rs)" \
  'grep -qE "^axum = \"0\.8\"" "$RUST/Cargo.toml" && grep -q "axum::serve" "$RUST/src/main.rs"'
check "both fixtures stay greenfield (no OTel)" \
  '! grep -rqiE "opentelemetry|open-telemetry" "$PHP" "$RUST"'

# --- freshness: both manifests are identity inputs, so neither service reads as always stale ---
check "the /otel-init identity regex covers composer.json and Cargo.toml" \
  'grep -q "Cargo\\\\.toml|Gemfile|composer\\\\.json" "$INIT"'

echo ""
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
