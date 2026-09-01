#!/usr/bin/env bash
# hooks/otel-paths.sh
# Single source of truth for "which files does otel-as-code generate?".
#
# Sourced by write-guard.sh (which protects them) and session-summary.sh (which reports
# them). Keeping one derived set here means adding a language — or an extension for a
# language already supported — cannot land in one hook and be silently dropped from the
# other. Hand-maintained parallel lists are how telemetry.ts ended up unguarded.
#
# This file only defines functions and arrays; it never executes anything.

# Bootstrap-module stems the generators emit. Every generated bootstrap is named
# <stem>.<ext>; nothing else is.
OTEL_STEMS=(tracing telemetry opentelemetry)

# Source extensions, one group per language the maturity matrix lists (supported today
# plus the v1 additions, so the guard is ready before the generator is).
#   nodejs  js mjs cjs ts mts cts     python  py       go  go
#   dotnet  cs                        ruby    rb       php php      rust rs
# Java is deliberately absent: it is instrumented by the Java agent, whose artifact is
# otel-java.env below — the generator never writes a tracing.java.
OTEL_EXTS=(js mjs cjs ts mts cts py go cs rb php rs)

# Fixed-name artifacts that carry no stem/extension pattern. OpenTelemetry.cs is the .NET SDK
# wiring class: matching here is exact and case-sensitive, and .NET convention names the file
# PascalCase, so the lowercase `opentelemetry.cs` produced by the stem×ext grid would NOT cover
# it — this line is what actually guards the generated .NET file.
OTEL_FIXED_NAMES=(otel-java.env otelcol-agent.yaml otelcol-gateway.yaml OpenTelemetry.cs)

# otel_is_generated_basename <basename> — true when the basename is one this plugin
# generates. Matching is exact (not a suffix glob), so a user's `request-tracing.js` is
# left alone while `tracing.js` is recognised.
#
# Trade-off, stated plainly: this matches by name alone, so an unrelated `telemetry.go`
# in a repo we never generated into is also recognised. That is the safe direction —
# a false positive costs one `--force`, a false negative costs the user's work.
otel_is_generated_basename() {
  local base="$1" name stem ext
  for name in "${OTEL_FIXED_NAMES[@]}"; do
    [ "$base" = "$name" ] && return 0
  done
  for stem in "${OTEL_STEMS[@]}"; do
    for ext in "${OTEL_EXTS[@]}"; do
      [ "$base" = "$stem.$ext" ] && return 0
    done
  done
  return 1
}

# otel_is_generated_path <path> — the same test applied to a full path.
otel_is_generated_path() {
  otel_is_generated_basename "$(basename "$1")"
}

# otel_bootstrap_globs — the glob patterns a command should use to find an existing
# bootstrap when the context cache does not name one. Printed one per line so callers
# can feed them straight to `find`/`ls`.
otel_bootstrap_globs() {
  local stem ext name
  for stem in "${OTEL_STEMS[@]}"; do
    for ext in "${OTEL_EXTS[@]}"; do
      printf '%s.%s\n' "$stem" "$ext"
    done
  done
  for name in "${OTEL_FIXED_NAMES[@]}"; do
    printf '%s\n' "$name"
  done
}
