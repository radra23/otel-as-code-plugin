#!/usr/bin/env bash
# Guards: golden bootstraps stay syntactically valid AND their pins match
# agents/instrumentation-gen.md (the single source for OTel SDK versions).
set -uo pipefail
cd "$(dirname "$0")/../../.."   # repo root
pass=0; fail=0
check() { if eval "$2"; then echo "PASS: $1"; pass=$((pass+1)); else echo "FAIL: $1"; fail=$((fail+1)); fi; }

# pins_match <package.json path> — every "@opentelemetry/pkg": "version" pair captured
# from the given package.json must appear verbatim (full name+version pair, NOT just
# the package name) as a substring of agents/instrumentation-gen.md. Prints
# "  drift: <pair>" per miss; returns nonzero if any pair is missing.
pins_match() {
  local target="$1" miss=0 pair
  while IFS= read -r pair; do
    grep -qF "$pair" agents/instrumentation-gen.md || { echo "  drift: $pair"; miss=1; }
  done < <(grep -oE "\"@opentelemetry/[^\"]+\": \"[^\"]+\"" "$target")
  [ "$miss" -eq 0 ]
}

# pins_match_dotnet <csproj path> — every `Include="OpenTelemetry.*" Version="X"` PackageReference
# in the golden .csproj must have the package name AND that version together on some line of
# agents/instrumentation-gen.md (the generator prints `dotnet add package <name>  # <version>`).
# The .NET package strings differ between csproj and the `dotnet add` form, so this matches
# name+version on the same line rather than a verbatim substring like the Node check.
pins_match_dotnet() {
  local target="$1" miss=0 pkg ver
  while IFS='|' read -r pkg ver; do
    grep -F "$pkg" agents/instrumentation-gen.md | grep -qF "$ver" \
      || { echo "  drift: $pkg $ver"; miss=1; }
  done < <(grep -oE 'Include="OpenTelemetry[^"]*" Version="[^"]+"' "$target" \
             | sed -E 's/Include="([^"]+)" Version="([^"]+)"/\1|\2/')
  [ "$miss" -eq 0 ]
}

# pins_match_go <go.mod path> — every DIRECT `go.opentelemetry.io/... vX.Y.Z` require line (the
# first `require (...)` block, excluding anything tagged `// indirect`) must have that exact
# module+version pair appear verbatim as a substring of agents/instrumentation-gen.md. Indirect
# requires are deliberately excluded — they're resolved by `go mod tidy`, never hand-authored or
# asserted by the doc, same reasoning as the Node/'.NET checks scoping to what's actually printed.
pins_match_go() {
  local target="$1" miss=0 pair
  while IFS= read -r pair; do
    grep -qF "$pair" agents/instrumentation-gen.md || { echo "  drift: $pair"; miss=1; }
  done < <(awk '/^require \(/{f=1;next} /^\)/{f=0} f && $0 !~ /\/\/ indirect/ {gsub(/^[ \t]+/,""); print}' "$target" \
             | grep -oE 'go\.opentelemetry\.io/\S+ v[0-9.]+')
  [ "$miss" -eq 0 ]
}

# pins_match_ruby <Gemfile path> — every `gem 'opentelemetry-...'` line in the golden Gemfile
# must have that exact gem name appear as a substring of agents/instrumentation-gen.md's Ruby
# section (Ruby's Gemfile intentionally carries no version pin — see the generator doc's own
# note on why — so this checks gem NAMES match, not name+version pairs like the Node/.NET/Go
# checks do).
pins_match_ruby() {
  local target="$1" miss=0 name
  while IFS= read -r name; do
    grep -qF "gem '$name'" agents/instrumentation-gen.md || { echo "  drift: gem '$name'"; miss=1; }
  done < <(grep -oE "gem '[^']*opentelemetry[^']*'" "$target" | sed -E "s/gem '([^']*)'/\1/")
  [ "$miss" -eq 0 ]
}

check "node bootstrap parses" 'node --check tests/snapshots/instrument/nodejs/tracing.js'
check "python bootstrap compiles" 'python3 -m py_compile tests/snapshots/instrument/python/tracing.py'
# every OTel pin (full name+version pair) in the golden package.json must appear in instrumentation-gen.md
check "node pins match generator" 'pins_match tests/snapshots/instrument/nodejs/package.json'

# Teeth check: proves pins_match actually compares versions, not just package names.
# Injects a version-only drift (^0.221.0 -> ^9.999.0) into a throwaway copy of the golden
# package.json and asserts pins_match correctly reports failure on it. Without this,
# a name-only check (the bug this fix addresses) would silently pass here too.
check "pin guard catches version drift (teeth check)" '
  tmp=$(mktemp -d)
  sed -E "s/(\"@opentelemetry\/sdk-node\": \")\^0\.222\.0\"/\1^9.999.0\"/" tests/snapshots/instrument/nodejs/package.json > "$tmp/package.json"
  drift_injected=0
  grep -qF "\"@opentelemetry/sdk-node\": \"^9.999.0\"" "$tmp/package.json" && drift_injected=1
  guard_caught_drift=0
  if [ "$drift_injected" -eq 1 ] && ! pins_match "$tmp/package.json" >/dev/null; then
    guard_caught_drift=1
  fi
  rm -rf "$tmp"
  [ "$drift_injected" -eq 1 ] && [ "$guard_caught_drift" -eq 1 ]'

# Java golden agent config: required OTEL_* keys present + gRPC protocol (paired with :4317
# throughout the plugin; the agent's own default is http/protobuf:4318, so grpc must be explicit).
check "java golden otel-java.env has required keys + grpc" '
  f=tests/snapshots/instrument/java/otel-java.env
  grep -q "^OTEL_SERVICE_NAME=" "$f" \
    && grep -q "deployment.environment.name=" "$f" \
    && grep -q "^OTEL_EXPORTER_OTLP_ENDPOINT=" "$f" \
    && grep -q "^OTEL_EXPORTER_OTLP_PROTOCOL=grpc$" "$f"'

# The pinned OTel Java agent version the e2e harness downloads (run.sh) must match the
# generator doc (agents/instrumentation-gen.md), so the two never drift apart.
check "java agent version pin matches generator" '
  v=$(grep -oE "OTEL_JAVA_AGENT_VERSION=[0-9.]+" tests/e2e/run.sh | head -1 | cut -d= -f2)
  [ -n "$v" ] && grep -qF "$v" agents/instrumentation-gen.md'

# .NET golden extension: carries the ownership marker (what the write-guard keys on), exposes the
# AddOtelObservability DI extension, and wires both signal pipelines. csc is not run here (offline
# lint job, no NuGet restore) — compilation is verified against a real ASP.NET Core project during
# development and by the e2e follow-up; this is the Java-style structural guard.
check ".NET golden has marker + extension signature + both pipelines" '
  f=tests/snapshots/instrument/dotnet/OpenTelemetry.cs
  grep -qi "generated by otel-as-code" "$f" \
    && grep -qF "IServiceCollection AddOtelObservability" "$f" \
    && grep -qF ".AddOpenTelemetry()" "$f" \
    && grep -qF ".WithTracing(" "$f" \
    && grep -qF ".WithMetrics(" "$f"'

# The golden .csproj name is the guarded PascalCase artifact; and every OTel package pin in it
# must match agents/instrumentation-gen.md (name+version on one line).
check ".NET pins match generator" 'pins_match_dotnet tests/snapshots/instrument/dotnet/checkout-api.csproj'

# Teeth check: prove pins_match_dotnet compares versions, not just names — inject a version-only
# drift into a throwaway copy of the golden csproj and assert the guard reports failure.
check ".NET pin guard catches version drift (teeth check)" '
  tmp=$(mktemp -d)
  sed -E "s/(Include=\"OpenTelemetry.Instrumentation.Http\" Version=\")1\.18\.0\"/\1""9.999.0\"/" \
    tests/snapshots/instrument/dotnet/checkout-api.csproj > "$tmp/x.csproj"
  drift_injected=0
  grep -qF "Include=\"OpenTelemetry.Instrumentation.Http\" Version=\"9.999.0\"" "$tmp/x.csproj" && drift_injected=1
  guard_caught=0
  if [ "$drift_injected" -eq 1 ] && ! pins_match_dotnet "$tmp/x.csproj" >/dev/null; then guard_caught=1; fi
  rm -rf "$tmp"
  [ "$drift_injected" -eq 1 ] && [ "$guard_caught" -eq 1 ]'

# Go golden bootstrap: carries the ownership marker, exposes InitOtel with the traces+metrics
# wiring, and includes the Beta logs add-on. go build is NOT run here (offline lint job, no Go
# toolchain) — compiling is verified during development (see this plan's provenance note) and by
# the e2e follow-up, same as the Java/.NET structural-only guards above.
check "Go golden has marker + InitOtel signature + Beta logs add-on" '
  f=tests/snapshots/instrument/go/tracing.go
  grep -qi "generated by otel-as-code" "$f" \
    && grep -qF "func InitOtel(ctx context.Context) (shutdown func(context.Context) error, err error)" "$f" \
    && grep -qF "func InitOtelLogsBeta(ctx context.Context)" "$f" \
    && grep -qF "otel.SetTracerProvider" "$f" \
    && grep -qF "otel.SetMeterProvider" "$f"'

check "Go pins match generator" 'pins_match_go tests/snapshots/instrument/go/go.mod'

# Teeth check: prove pins_match_go compares versions, not just names.
check "Go pin guard catches version drift (teeth check)" '
  tmp=$(mktemp -d)
  sed -E "s#(go\.opentelemetry\.io/otel v)1\.46\.0#\19.999.0#" \
    tests/snapshots/instrument/go/go.mod > "$tmp/go.mod"
  drift_injected=0
  grep -qF "go.opentelemetry.io/otel v9.999.0" "$tmp/go.mod" && drift_injected=1
  guard_caught=0
  if [ "$drift_injected" -eq 1 ] && ! pins_match_go "$tmp/go.mod" >/dev/null; then guard_caught=1; fi
  rm -rf "$tmp"
  [ "$drift_injected" -eq 1 ] && [ "$guard_caught" -eq 1 ]'

# Ruby golden bootstrap: carries the ownership marker, the OTEL_TRACES_EXPORTER no-op guard, and
# use_all. `ruby -c` is NOT run here (offline lint job, no Ruby toolchain) — compiling/running is
# verified during development (see this plan's provenance note) and by the e2e follow-up, same as
# the Java/.NET/Go structural-only guards above.
check "Ruby golden has marker + no-op guard + use_all" '
  f=tests/snapshots/instrument/ruby/tracing.rb
  grep -qi "generated by otel-as-code" "$f" \
    && grep -qF "OTEL_TRACES_EXPORTER" "$f" \
    && grep -qF "||=" "$f" \
    && grep -qF "c.use_all" "$f" \
    && grep -qF "OpenTelemetry::SDK.configure" "$f"'

check "Ruby pins match generator (gem names)" 'pins_match_ruby tests/snapshots/instrument/ruby/Gemfile'

# Teeth check: prove pins_match_ruby actually reads the golden file, not a vacuous pass — inject a
# renamed gem into a throwaway copy and assert the guard reports failure.
check "Ruby pin guard catches a renamed/missing gem (teeth check)" '
  tmp=$(mktemp -d)
  sed -E "s/opentelemetry-sdk/opentelemetry-sdk-renamed/" \
    tests/snapshots/instrument/ruby/Gemfile > "$tmp/Gemfile"
  drift_injected=0
  grep -q "opentelemetry-sdk-renamed" "$tmp/Gemfile" && drift_injected=1
  guard_caught=0
  if [ "$drift_injected" -eq 1 ] && ! pins_match_ruby "$tmp/Gemfile" >/dev/null; then guard_caught=1; fi
  rm -rf "$tmp"
  [ "$drift_injected" -eq 1 ] && [ "$guard_caught" -eq 1 ]'

echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
