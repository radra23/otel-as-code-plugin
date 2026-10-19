#!/usr/bin/env bash
# tests/e2e/dotnet-placement.sh
# Proves #182: where the generator writes OpenTelemetry.cs decides whether it compiles.
# Builds fixtures/dotnet-nested (solution at the root, project one level down) twice:
#   1. the file at the solution folder (the old "service root" rule)  -> must FAIL to build
#   2. the file where the new rule puts it: the first directory at or above runnableEntry that
#      holds a *.csproj                                                -> must BUILD
# Uses the golden OpenTelemetry.cs and csproj (the instrumented state /otel-instrument leaves).
# Needs the .NET SDK (preinstalled on GitHub's ubuntu runners) and access to nuget.org.
set -uo pipefail
cd "$(dirname "$0")/../.."
SRC=$PWD
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

seed() { rm -rf "$WORK/repo"; cp -R fixtures/dotnet-nested "$WORK/repo"; cp tests/snapshots/instrument/dotnet/checkout-api.csproj "$WORK/repo/src/Svc/Svc.csproj"; }

# The rule from agents/instrumentation-gen.md: start at runnableEntry's directory, walk up to the
# first directory containing a *.csproj.
resolve_dir() {
  local d; d=$(dirname "$1")
  while [ "$d" != "$WORK/repo" ] && [ "$d" != "/" ]; do
    ls "$d"/*.csproj >/dev/null 2>&1 && { echo "$d"; return; }
    d=$(dirname "$d")
  done
  echo "$WORK/repo"
}

rc=0

seed
cp "$SRC/tests/snapshots/instrument/dotnet/OpenTelemetry.cs" "$WORK/repo/OpenTelemetry.cs"      # the old rule: rootDir
out=$(cd "$WORK/repo" && dotnet build svc.sln -nologo -v q 2>&1)   # captured: grep -q + pipefail would race
if grep -q "error CS0246.*'CheckoutApi'" <<<"$out"; then
  echo "PASS: with the file at the solution folder, the project cannot see the generated namespace (CS0246; the premise of #182)"
else
  echo "FAIL: a file at the solution folder compiled; the premise of #182 no longer holds" >&2; rc=1
fi

seed
target=$(resolve_dir "$WORK/repo/src/Svc/Program.cs")
cp "$SRC/tests/snapshots/instrument/dotnet/OpenTelemetry.cs" "$target/OpenTelemetry.cs"           # the new rule
case "$target" in */src/Svc) ;; *) echo "FAIL: the placement rule resolved '$target', expected src/Svc" >&2; rc=1;; esac
out=$(cd "$WORK/repo" && dotnet build svc.sln -nologo -v q 2>&1)
if grep -q '0 Error' <<<"$out"; then
  echo "PASS: with the file beside the project (${target#"$WORK/repo/"}), the solution builds"
else
  echo "FAIL: the solution does not build with the file placed by the new rule" >&2; rc=1
fi
exit $rc
