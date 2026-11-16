#!/usr/bin/env bash
# tests/e2e/go-legacy-line.sh
# The Go bootstrap for a project still on Go 1.25 or older. OpenTelemetry Go v1.47.0 needs Go
# 1.26, so for such a project the generator keeps the v1.46 line (the last that builds there),
# where the Logs API is still Beta and has no otel.SetLoggerProvider. The generator gets there
# from the current template by the three substitutions agents/instrumentation-gen.md lists under
# "Go below 1.26"; this applies exactly those to the golden tracing.go, puts it next to the
# fixture's main.go and the legacy go.mod/go.sum (tests/snapshots/instrument/go/legacy/), and
# builds it. Run in CI on Go 1.25, which is the point; any newer Go builds it too.
# Needs a Go toolchain and network for the module download. No Docker.
set -euo pipefail
cd "$(dirname "$0")/../.."
SRC=$PWD
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
GO=${GO:-go}

cp "$SRC/fixtures/go-greenfield/main.go" "$WORK/"
cp "$SRC/tests/snapshots/instrument/go/legacy/go.mod" "$SRC/tests/snapshots/instrument/go/legacy/go.sum" "$WORK/"
python3 - "$SRC/tests/snapshots/instrument/go/tracing.go" "$WORK/tracing.go" <<'PY'
import sys
src, dst = sys.argv[1:3]
text = open(src, encoding="utf-8").read()
SUBSTITUTIONS = [
    # 1. the import the v1.46 line needs for its global logger provider
    ('\t"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"\n',
     '\t"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"\n\tlogglobal "go.opentelemetry.io/otel/log/global"\n'),
    # 2. the setter: otel.SetLoggerProvider does not exist before v1.47.0
    ("\totel.SetLoggerProvider(loggerProvider)\n", "\tlogglobal.SetLoggerProvider(loggerProvider)\n"),
    # 3. the comment: on this line logs are Beta
    ("// Logs. The Logs API and SDK are stable since OpenTelemetry Go v1.47.0; the\n"
     "// OTLP log exporter (otlploggrpc) is still pre-1.0 and its options may change.\n",
     "// Logs (Beta on the v1.46 line this project's Go version is held to: the API\n"
     "// may change, and it becomes stable with OpenTelemetry Go v1.47.0 on Go 1.26).\n"),
]
for old, new in SUBSTITUTIONS:
    if text.count(old) != 1:
        sys.exit(f"substitution target found {text.count(old)} times, expected once: {old!r}")
    text = text.replace(old, new)
open(dst, "w", encoding="utf-8").write(text)
PY
cd "$WORK"
echo "toolchain: $($GO version)"
grep -q '^go 1\.25' go.mod || { echo "FAIL: the legacy go.mod is expected to declare go 1.25"; exit 1; }
grep -q 'go.opentelemetry.io/otel v1.46.0' go.mod || { echo "FAIL: the legacy go.mod is expected to pin the v1.46 line"; exit 1; }
$GO build ./... && echo "PASS: the Go bootstrap builds on the v1.46 line with the three documented substitutions"
$GO vet ./... && echo "PASS: go vet is clean"
cp go.sum "$WORK/go.sum.after"
cmp -s go.sum "$SRC/tests/snapshots/instrument/go/legacy/go.sum" \
  && echo "PASS: the build needed nothing beyond the committed legacy go.sum" \
  || { echo "FAIL: the build changed go.sum; the committed legacy module files are incomplete"; exit 1; }
echo "GO LEGACY LINE PASS"
