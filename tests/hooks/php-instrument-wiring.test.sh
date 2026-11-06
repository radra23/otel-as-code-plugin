#!/usr/bin/env bash
# tests/hooks/php-instrument-wiring.test.sh
# Locks PHP's wiring (#117) across the scanner gate, /otel-instrument, the generator and the
# golden fixture. The golden composer.json/telemetry.php are compared to the generator's own
# template text, so a change to one without the other fails here, offline.
# Supersedes tests/hooks/php-refusal.test.sh (deleted): PHP is no longer refused, it generates.
set -uo pipefail
cd "$(dirname "$0")/../.."
pass=0; fail=0
check() { if eval "$2"; then echo "PASS: $1"; pass=$((pass+1)); else echo "FAIL: $1"; fail=$((fail+1)); fi; }

SCANNER="agents/repo-context-scanner.md"
CMD="commands/otel-instrument.md"
GEN="agents/instrumentation-gen.md"
MAT="skills/language-maturity/SKILL.md"
INIT="commands/otel-init.md"
GOLD="tests/snapshots/instrument/php"
FIX="fixtures/php-laravel-app"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# --- scanner gate: no refusal case, framework decides placement only ---
check "scanner: php is generatorSupported:true unconditionally, no framework refusal" \
  'grep -qF "For \`php\` it is \`true\` unconditionally" "$SCANNER" \
   && grep -qF "there is no framework refusal case" "$SCANNER"'
check "scanner: brownfield exclusion is open-telemetry/* already in composer.json" \
  'grep -qF "an \`open-telemetry/sdk\` (or any \`open-telemetry/*\`) entry" "$SCANNER" \
   && grep -qF "already in \`composer.json\`" "$SCANNER"'
check "scanner: laravel/symfony are framework enum values, detected from composer.json require" \
  'grep -qF "laravel\`, \`symfony\`, \`other\`, \`unknown\`" "$SCANNER" \
   && grep -qF "laravel/framework\` entry in \`composer.json\`" "$SCANNER" \
   && grep -qF "symfony/framework-bundle\` or a bare \`symfony/symfony\`" "$SCANNER"'
check "scanner: existing-OTel detection covers open-telemetry/ in composer.json" \
  'grep -qF "open-telemetry/\` in \`composer.json\`" "$SCANNER"'
check "scanner no longer claims php is outside today's codegen" \
  '! grep -q "php.*outside today.s codegen" "$SCANNER"'

# --- command ---
check "otel-instrument lists php as supported, not v1-only" \
  'grep -qF "rust, php." "$CMD" && ! grep -q "v1 will add: php" "$CMD"'
check "otel-instrument documents composer validate + php -l as the PHP smoke check" \
  'grep -qF "For **PHP** the equivalent check is \`composer validate && php -l telemetry.php\`" "$CMD"'

# --- maturity ---
check "language-maturity: runtime php is in scope" \
  'grep -qE "^\| \`php\` +\| yes" "$MAT"'
check "language-maturity: PHP row says all three core signals are Stable, no --experimental needed" \
  'grep -qF "### PHP" "$MAT" \
   && grep -qF "PHP needs no \`--experimental\` gating for any of the three core signals" "$MAT"'
check "language-maturity: PHP's own SDK-default gotcha (otlp+localhost, not a no-op) is documented" \
  'grep -qiF "otlp enabled + localhost" "$MAT"'
check "PHP removed from the v1-additions stub table (it is a real section now)" \
  'grep -qF "PHP shipped (#117)" "$MAT" && ! grep -qE "^\| PHP +\| Stable +\| Stable +\| Stable" "$MAT"'

# --- generator ---
check "instrumentation-gen defines the PHP section" \
  'grep -qF "## PHP (Laravel / Symfony / framework-agnostic" "$GEN"'
check "generator states there is no framework refusal case for PHP" \
  'grep -qF "**There is no framework refusal case**" "$GEN"'
check "generator documents the none-unless-configured exporter guard and why it is needed" \
  'grep -qF "OTEL_TRACES_EXPORTER" "$GEN" && grep -qF "does NOT no-op on" "$GEN" \
   && grep -qF "http://localhost:4318" "$GEN"'
check "generator gates the Monolog logs bridge on Monolog being detected, prints it as an add-on" \
  'grep -qF "monolog/monolog" "$GEN" && grep -qF "printed as a separate add-on" "$GEN"'
check "generator prints the PECL extension + php.ini step as a host change it cannot make itself" \
  'grep -qiF "pecl install opentelemetry" "$GEN" \
   && grep -qiF "this plugin cannot touch the host" "$GEN"'
check "generator explicitly says the PHP bootstrap was not runtime-verified (no PHP toolchain available)" \
  'grep -qF "This file is NOT independently runtime-verified" "$GEN"'

# Extract the generator's telemetry.php template and fill the placeholders with the golden's values.
awk '/^```php$/{f++; if(f==1){g=1;next}} g&&/^```$/{exit} g' "$GEN" \
  | sed -e "s/<SEMCONV_VERSION>/$(grep -oE 'SEMCONV_VERSION: [0-9.]+' skills/semconv-discipline/SKILL.md | cut -d' ' -f2)/" \
        -e 's/<PLUGIN_VERSION>/0.8.25/' \
        -e "s/getenv('OTEL_SERVICE_NAME') ?: '<SERVICE_NAME>'/getenv('OTEL_SERVICE_NAME') ?: 'billing-api'/" \
        -e "s/getenv('OTEL_SERVICE_VERSION') ?: '<SERVICE_VERSION>'/getenv('OTEL_SERVICE_VERSION') ?: '1.0.0'/" \
        -e "s/getenv('DEPLOYMENT_ENV') ?: '<DEPLOYMENT_ENV>'/getenv('DEPLOYMENT_ENV') ?: 'development'/" \
  | grep -v "service.namespace\|otherwise delete this line rather than emit a placeholder" > "$tmp/telemetry.php"
check "golden telemetry.php is the generator's template, filled in (no confirmed namespace -> line dropped)" \
  'test -s "$tmp/telemetry.php" && diff -u "$tmp/telemetry.php" "$GOLD/telemetry.php"'
check "golden telemetry.php keeps the exporter guard, provider registration, and shutdown function" \
  'grep -q "endpointSet ? .otlp. : .none." "$GOLD/telemetry.php" \
   && grep -q "withTracerProvider" "$GOLD/telemetry.php" \
   && grep -q "register_shutdown_function" "$GOLD/telemetry.php"'

# The composer.json require block, verbatim from the generator (the core + laravel pins).
awk '/^```json$/{f++; if(f==2){g=1;next}} g&&/^```$/{exit} g' "$GEN" > "$tmp/core_block.json"
check "golden composer.json carries every core OTel package the generator's json block lists" \
  'core_pkgs=$(grep -oE "\"open-telemetry/[a-z-]+\":" "$tmp/core_block.json" | tr -d "\":"); \
   missing=0; for p in $core_pkgs; do grep -qF "\"$p\":" "$GOLD/composer.json" || missing=1; done; \
   [ -s "$tmp/core_block.json" ] && [ "$missing" -eq 0 ]'
check "golden composer.json (Laravel) also carries the laravel auto-instrumentation package" \
  'grep -qF "open-telemetry/opentelemetry-auto-laravel" "$GOLD/composer.json"'

# --- guard + fixture ---
check "write-guard protects telemetry.php (otel-paths)" \
  '( source hooks/otel-paths.sh && otel_is_generated_path /x/telemetry.php )'
check "php fixture is a Laravel app (composer.json requires laravel/framework), stays greenfield" \
  'grep -qF "\"laravel/framework\"" "$FIX/composer.json" && test -f "$FIX/artisan" && test -f "$FIX/routes/web.php" \
   && ! grep -rqiE "opentelemetry|open-telemetry" "$FIX"'

# --- freshness: the manifest is an identity input, so the service never reads as always stale ---
check "the /otel-init identity regex covers composer.json" \
  'grep -q "composer\\\\.json" "$INIT"'

echo ""
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
