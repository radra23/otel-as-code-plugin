#!/usr/bin/env bash
# tests/hooks/rust-instrument-wiring.test.sh
# Locks Rust's wiring (#118) across the scanner gate, /otel-instrument, the generator and the
# golden crate. The golden files are compared to the generator's own template text, so a change
# to one without the other fails here, offline. The golden crate is compiled by the
# rust-golden job in ci.yml.
set -uo pipefail
cd "$(dirname "$0")/../.."
pass=0; fail=0
check() { if eval "$2"; then echo "PASS: $1"; pass=$((pass+1)); else echo "FAIL: $1"; fail=$((fail+1)); fi; }

SCANNER="agents/repo-context-scanner.md"
CMD="commands/otel-instrument.md"
GEN="agents/instrumentation-gen.md"
MAT="skills/language-maturity/SKILL.md"
GOLD="tests/snapshots/instrument/rust"
FIX="fixtures/rust-axum-app"
GOLD_ACTIX="tests/snapshots/instrument/rust-actix"
FIX_ACTIX="fixtures/rust-actix-app"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# --- scanner gate: axum 0.8 or actix-web 4.x, every other shape refused with a reason ---
check "scanner: rust is generatorSupported for an axum 0.8 OR an actix-web 4.x binary" \
  'grep -q "For \`rust\` it is \`true\` for an axum 0.8 binary OR an actix-web 4.x binary" "$SCANNER"'
check "scanner: actix-web gate requires actix-web 4.x, a binary target, and HttpServer...run()" \
  'grep -q "\*\*actix-web\*\*: ALL of these must hold" "$SCANNER" \
   && grep -qF "\`actix-web\` in \`[dependencies]\` with a requirement that resolves to 4.x" "$SCANNER" \
   && grep -qF "an \`HttpServer::new(...)\` call that reaches \`.run()\`" "$SCANNER"'
check "scanner: other frameworks, axum < 0.8 and no-server still stay refused (actix-web no longer among them)" \
  'grep -q "rocket\`" "$SCANNER" && grep -q "warp\`" "$SCANNER" && grep -q "poem\`" "$SCANNER" && grep -q "axum 0.7" "$SCANNER" \
   && ! grep -q "actix-web is planned, not yet supported" "$SCANNER"'
check "scanner: a rust library crate is inScope:false" \
  'grep -q "inScope:false — rust library crate" "$SCANNER"'
check "scanner: axum and actix-web are both framework enum values (prose and schema)" \
  'grep -q "\`nuxt\`, \`axum\`, \`actix-web\`, \`aspnetcore\`" "$SCANNER" && grep -q "nuxt|axum|actix-web|aspnetcore" "$SCANNER"'

# --- command ---
check "otel-instrument lists rust as supported and no longer as coming in v1" \
  'grep -q "go, ruby,$" "$CMD" && grep -qF "rust, php." "$CMD" && ! grep -q "v1 will add" "$CMD"'
check "otel-instrument documents cargo check as the Rust smoke check" \
  'grep -q "For \*\*Rust\*\* the equivalent check is \`cargo check\`" "$CMD"'

# --- maturity ---
check "language-maturity: runtime rust is in scope, traces Beta, metrics/logs Stable" \
  'grep -qE "^\| \`rust\` +\| yes" "$MAT" && grep -qE "^\| Traces +\| Beta +\| \`opentelemetry_sdk\`" "$MAT"'

# --- generator ---
check "instrumentation-gen defines the Rust section" \
  'grep -q "^## Rust (axum 0.8" "$GEN"'
check "generator enables the tower crate's axum feature (http.route depends on it)" \
  'grep -qF "opentelemetry-instrumentation-tower = { version = \"0.19\", features = [\"axum\"] }" "$GEN"'
check "generator enables the actix-web crate's metrics feature (no metrics at all without it)" \
  'grep -qF "opentelemetry-instrumentation-actix-web = { version = \"0.25\", features = [\"metrics\"] }" "$GEN"'
check "generator documents why tracing-actix-web and actix-web-opentelemetry are avoided" \
  'grep -qF "Use \`opentelemetry-instrumentation-actix-web\`, never" "$GEN" \
   && grep -qF "http.method" "$GEN" && grep -qF "http.status_code" "$GEN" \
   && grep -q "actix-web-opentelemetry\` is deprecated upstream" "$GEN"'
check "generator warns that let _ = drops the guard" \
  'grep -qF "let _ = telemetry::init();" "$GEN" && grep -qF "let _otel = telemetry::init();" "$GEN"'
check "generator states telemetry.rs is identical for axum and actix-web" \
  'grep -qF "This file is identical for axum and actix-web" "$GEN"'

# Extract the generator's telemetry.rs template and fill the placeholders with the golden's values.
awk '/^### `src\/telemetry.rs`/{f=1} f&&/^```rust$/{g=1;next} g&&/^```$/{exit} g' "$GEN" \
  | sed -e "s/<SEMCONV_VERSION>/$(grep -oE 'SEMCONV_VERSION: [0-9.]+' skills/semconv-discipline/SKILL.md | cut -d' ' -f2)/" \
        -e 's/<SERVICE_NAME>/search-api/g' -e 's/<SERVICE_VERSION>/0.4.0/' \
        -e 's/<SERVICE_NAMESPACE>/storefront/' -e 's/<DEPLOYMENT_ENV>/development/' > "$tmp/telemetry.rs"
check "golden telemetry.rs is the generator template, filled in" \
  'test -s "$tmp/telemetry.rs" && diff -u "$tmp/telemetry.rs" "$GOLD/src/telemetry.rs"'
check "golden telemetry.rs keeps the propagator, the log-loop filter and the flushing guard" \
  'grep -q "set_text_map_propagator" "$GOLD/src/telemetry.rs" && grep -q "reqwest=off" "$GOLD/src/telemetry.rs" && grep -q "impl Drop for TelemetryGuard" "$GOLD/src/telemetry.rs"'
check "golden telemetry.rs puts the Beta comment on traces only" \
  '[ "$(grep -c "Beta signal" "$GOLD/src/telemetry.rs")" -eq 1 ] && grep -A1 "Beta signal" "$GOLD/src/telemetry.rs" | grep -q SdkTracerProvider'

# The marked Cargo.toml block, verbatim from the generator.
awk '/^### Update `Cargo.toml`/{f=1} f&&/^```toml$/{g=1;next} g&&/^```$/{exit} g' "$GEN" > "$tmp/block"
check "golden Cargo.toml = fixture Cargo.toml + the generator's marked block" \
  'test -s "$tmp/block" && cat "$FIX/Cargo.toml" "$tmp/block" | diff -u - "$GOLD/Cargo.toml"'

# main.rs = fixture + the three printed lines, nothing else: drop those lines from the golden
# (and the blank line after `mod telemetry;`), give the last route back its `;`, and it must be
# the fixture byte for byte.
check "golden main.rs = fixture main.rs + the three printed wiring lines" \
  'grep -qx "mod telemetry;" "$GOLD/src/main.rs" \
   && grep -qx "    let _otel = telemetry::init();" "$GOLD/src/main.rs" \
   && grep -qx "        .layer(opentelemetry_instrumentation_tower::http::server::Layer::new());" "$GOLD/src/main.rs" \
   && sed -e "1{/^mod telemetry;$/d;}" -e "2{/^$/d;}" "$GOLD/src/main.rs" \
      | grep -vx "    let _otel = telemetry::init();" \
      | grep -vx "        .layer(opentelemetry_instrumentation_tower::http::server::Layer::new());" \
      | sed "/^        .route(\"\/healthz\"/s/\$/;/" \
      | diff -u "$FIX/src/main.rs" -'

# --- actix-web: telemetry.rs is byte-identical to axum's golden (proves the "framework-agnostic
# file" claim rather than just asserting it) ---
check "golden actix telemetry.rs is byte-identical to golden axum telemetry.rs" \
  'diff -q "$GOLD/src/telemetry.rs" "$GOLD_ACTIX/src/telemetry.rs" >/dev/null'

# The SECOND marked Cargo.toml block in the Rust section (the first is axum's, already checked
# above) — the actix-web-specific pins, verbatim from the generator.
awk '/^### Update `Cargo.toml`/{f=1} f&&/^```toml$/{c++; if(c==2){g=1;next}} g&&/^```$/{exit} g' "$GEN" > "$tmp/actix_block"
check "golden actix Cargo.toml = fixture Cargo.toml + the generator's SECOND (actix-web) marked block" \
  'test -s "$tmp/actix_block" && cat "$FIX_ACTIX/Cargo.toml" "$tmp/actix_block" | diff -u - "$GOLD_ACTIX/Cargo.toml"'
check "the two marked Cargo.toml blocks actually differ (teeth check: not comparing a block against itself)" \
  '! diff -q "$tmp/block" "$tmp/actix_block" >/dev/null'

# main.rs = fixture + telemetry::init() + both .wrap(...) calls, nothing else: drop those exact
# lines (and the blank line after `mod telemetry;`) and it must be the fixture byte for byte.
check "golden actix main.rs = fixture main.rs + the printed wiring lines" \
  'grep -qx "mod telemetry;" "$GOLD_ACTIX/src/main.rs" \
   && grep -qx "    let _otel = telemetry::init();" "$GOLD_ACTIX/src/main.rs" \
   && grep -qx "            .wrap(opentelemetry_instrumentation_actix_web::RequestTracing::new())" "$GOLD_ACTIX/src/main.rs" \
   && grep -qx "            .wrap(opentelemetry_instrumentation_actix_web::RequestMetrics::default())" "$GOLD_ACTIX/src/main.rs" \
   && sed -e "1{/^mod telemetry;$/d;}" -e "2{/^$/d;}" "$GOLD_ACTIX/src/main.rs" \
      | grep -vx "    let _otel = telemetry::init();" \
      | grep -vx "            .wrap(opentelemetry_instrumentation_actix_web::RequestTracing::new())" \
      | grep -vx "            .wrap(opentelemetry_instrumentation_actix_web::RequestMetrics::default())" \
      | diff -u "$FIX_ACTIX/src/main.rs" -'

# --- guard + fixtures ---
check "write-guard protects telemetry.rs (otel-paths)" \
  '( source hooks/otel-paths.sh && otel_is_generated_path /x/src/telemetry.rs )'
check "rust fixture is a greenfield axum 0.8 binary" \
  'grep -qE "^axum = \"0\.8\"" "$FIX/Cargo.toml" && grep -q "axum::serve" "$FIX/src/main.rs" && ! grep -rqi opentelemetry "$FIX"'
check "rust-actix fixture is a greenfield actix-web 4.x binary" \
  'grep -qE "^actix-web = \"4\"" "$FIX_ACTIX/Cargo.toml" && grep -q "HttpServer::new" "$FIX_ACTIX/src/main.rs" && grep -q "\.run()" "$FIX_ACTIX/src/main.rs" && ! grep -rqi opentelemetry "$FIX_ACTIX"'

echo ""
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
