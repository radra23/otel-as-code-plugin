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

# Fixed-name artifacts that carry no stem/extension pattern, SPLIT by what generates them.
# The split is load-bearing for destructive consumers: /otel-uninstrument deletes and must reach
# bootstraps ONLY, never a Collector config — and the ownership marker cannot save the latter,
# because /otel-collector stamps its output with the same marker. A bootstrap-scoped consumer
# therefore has to be handed a name set that excludes the collector configs by construction, not
# by prose. otel_is_generated_*() below matches the UNION (OTEL_FIXED_NAMES), because the
# write-guard must protect and session-summary must report both kinds.
#
# OpenTelemetry.cs is the .NET SDK wiring class: matching is exact and case-sensitive, and .NET
# convention names the file PascalCase, so the lowercase `opentelemetry.cs` produced by the
# stem×ext grid would NOT cover it — this entry is what actually guards the generated .NET file.
#
# The local-stack names (/otel-local) are a third group for the same reason as the Collector
# configs: they are not a service's bootstrap. otel-local.compose.yaml is ONE stack shared by every
# service in the repo, so /otel-uninstrument, which works per service, must never reach it (nor a
# service's otel-local.env, which /otel-local --down removes together with the stack). They carry
# the same marker, so again only construction keeps them out of the destructive set.
OTEL_BOOTSTRAP_FIXED_NAMES=(otel-java.env OpenTelemetry.cs)
OTEL_COLLECTOR_FIXED_NAMES=(otelcol-agent.yaml otelcol-gateway.yaml)
OTEL_LOCAL_STACK_FIXED_NAMES=(otel-local.compose.yaml otel-local.env)
# The telemetry test /otel-test writes into a service's directory (scripts/telemetry_test.py owns
# the two names). It is per service like a bootstrap, and /otel-uninstrument removes it with the
# bootstrap, but it is NOT a bootstrap: it gets its own accessor (otel_test_globs) so that
# /otel-instrument's "is there a bootstrap already?" scan never mistakes a test for one.
OTEL_TEST_FIXED_NAMES=(otel.test.cjs test_otel.py)
OTEL_FIXED_NAMES=("${OTEL_BOOTSTRAP_FIXED_NAMES[@]}" "${OTEL_COLLECTOR_FIXED_NAMES[@]}" "${OTEL_LOCAL_STACK_FIXED_NAMES[@]}" "${OTEL_TEST_FIXED_NAMES[@]}")

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

# Terraform module files /otel-backend writes. Protected in ANY directory (a custom --output-dir
# included), but only when they carry the ownership marker, so a hand-written main.tf is untouched.
OTEL_TF_MODULE_NAMES=(main.tf variables.tf outputs.tf)

# otel_is_tf_module_basename <basename>: true for one of OTEL_TF_MODULE_NAMES (exact match).
otel_is_tf_module_basename() {
  local name
  for name in "${OTEL_TF_MODULE_NAMES[@]}"; do
    [ "$1" = "$name" ] && return 0
  done
  return 1
}

# otel_bootstrap_globs — the BOOTSTRAP names only (stems×exts + OTEL_BOOTSTRAP_FIXED_NAMES).
# Printed one per line so callers can feed them straight to `find`/`ls`. Use this to find or act
# on an SDK bootstrap: it deliberately EXCLUDES the Collector configs, so a destructive consumer
# (/otel-uninstrument) cannot reach an otelcol-*.yaml through it, and /otel-instrument's
# find-existing scan does not trip over a Collector config either.
otel_bootstrap_globs() {
  local stem ext name
  for stem in "${OTEL_STEMS[@]}"; do
    for ext in "${OTEL_EXTS[@]}"; do
      echo "$stem.$ext"
    done
  done
  for name in "${OTEL_BOOTSTRAP_FIXED_NAMES[@]}"; do
    echo "$name"
  done
}

# otel_test_globs: the telemetry-test names only. /otel-uninstrument deletes these (marker-gated)
# together with the service's bootstrap; nothing else may treat them as a bootstrap.
otel_test_globs() {
  local name
  for name in "${OTEL_TEST_FIXED_NAMES[@]}"; do
    echo "$name"
  done
}

# otel_all_generated_globs: EVERY generated name (bootstrap + Collector + local-stack + test fixed
# names). For read-only reporting (session-summary) that should surface those too. Never hand
# this to a destructive consumer.
otel_all_generated_globs() {
  local name
  otel_bootstrap_globs
  for name in "${OTEL_COLLECTOR_FIXED_NAMES[@]}" "${OTEL_LOCAL_STACK_FIXED_NAMES[@]}" "${OTEL_TEST_FIXED_NAMES[@]}"; do
    echo "$name"
  done
}
