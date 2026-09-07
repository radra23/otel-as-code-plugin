#!/usr/bin/env bash
# hooks/semconv-lint.sh
# PostToolUse hook — advisory semconv lint on OTel file writes.
# Always exits 0 (advisory only, unless strict mode — see below). Writes warnings to stdout.

set -euo pipefail

# Resolve the pinned semconv version from its single source of truth (the semconv-discipline
# skill) instead of hardcoding it here. Falls back to "unknown" if the skill can't be read.
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SEMCONV_SKILL="$PLUGIN_ROOT/skills/semconv-discipline/SKILL.md"
SEMCONV_VERSION=$(grep -oE 'SEMCONV_VERSION:[[:space:]]*[0-9]+\.[0-9]+\.[0-9]+' \
  "$SEMCONV_SKILL" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
SEMCONV_VERSION="${SEMCONV_VERSION:-unknown}"

# Strict mode: hard-block (exit 2) on SEVERE violations instead of only warning. Opt-in via
# OTEL_STRICT=1 (env, for CI) or a .claude/.otel-strict sentinel file (mirrors write-guard's
# --force pattern so a repo/session can enable it). Default stays advisory (always exit 0).
STRICT=0
[ "${OTEL_STRICT:-0}" = "1" ] && STRICT=1
STRICT_SENTINEL="${CLAUDE_PROJECT_DIR:-$(pwd)}/.claude/.otel-strict"
[ -f "$STRICT_SENTINEL" ] && STRICT=1

# Resolve a JSON parser that ACTUALLY RUNS (jq is not assumed). `command -v` is not enough: on
# Windows `python3` is commonly an App Execution Alias stub that is on PATH and resolves but
# errors when run — trusting it left the lint parsing nothing, so strict mode's block guarantee
# silently evaporated. Verify each candidate by executing it; the first working one wins (a real
# Python is often `python` when `python3` is the stub). If none run: in strict mode fail closed
# (exit 2), in advisory (default) mode skip quietly (exit 0). OTEL_HOOK_PYTHON overrides the probe
# (the tests set it — empty — to simulate absence); when set it is the only candidate and must run.
py_runs() { printf '' | "$@" -c 'pass' >/dev/null 2>&1; }
PY=""
if [ "${OTEL_HOOK_PYTHON+set}" = "set" ]; then
  if [ -n "$OTEL_HOOK_PYTHON" ] && py_runs "$OTEL_HOOK_PYTHON"; then PY="$OTEL_HOOK_PYTHON"; fi
else
  for cand in python3 python; do
    if command -v "$cand" >/dev/null 2>&1 && py_runs "$cand"; then PY="$cand"; break; fi
  done
fi
if [ -z "$PY" ]; then
  echo "otel-as-code semconv-lint: no WORKING python found (python3/python absent or non-functional — on Windows, python3 may be a Store alias stub). Cannot lint this write." >&2
  [ "$STRICT" -eq 1 ] && exit 2 || exit 0
fi

INPUT=$(cat)

# Extract file path written
FILE_PATH=$(echo "$INPUT" | "$PY" -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('tool_input', {}).get('file_path', ''))
" 2>/dev/null || echo "")

if [ ! -f "$FILE_PATH" ]; then
  exit 0
fi

CONTENT=$(cat "$FILE_PATH" 2>/dev/null || echo "")

# --- Gate: does this file actually reference an OTel API? (#138 gate 1) --------------------------
# A basename substring check (the old gate) only matched files literally named tracing/telemetry/
# instrumentation/opentelemetry — the bootstrap/wiring file. Attributes are set in handlers and
# services, which are never named that. Every official OTel package/namespace, in every one of
# the six supported languages, contains the substring "opentelemetry" somewhere in its import path
# or namespace (@opentelemetry/*, opentelemetry.*, io.opentelemetry.*, OpenTelemetry.*,
# go.opentelemetry.io/*, OpenTelemetry::*) — so a single case-insensitive content check covers all
# six without an enumerated per-language import-pattern list to keep in sync.
#
# .NET is the one language where that alone under-detects: application code that creates spans
# via System.Diagnostics.ActivitySource / records metrics via System.Diagnostics.Metrics.Meter
# routinely never mentions "OpenTelemetry" by name at all — only the SDK-wiring file does, since
# ActivitySource/Meter are .NET's own built-in diagnostics types that the OTel SDK listens to, not
# OTel-namespaced types. Gate on those explicitly too. Meter is matched as a call/constructor
# (`Meter(`) rather than a bare word, to avoid tripping on an unrelated `Meter` identifier.
is_otel_file=0
if echo "$CONTENT" | grep -qi "opentelemetry"; then
  is_otel_file=1
elif echo "$CONTENT" | grep -qE "ActivitySource|System\.Diagnostics\.Metrics|[[:space:]]Meter\("; then
  is_otel_file=1
fi

if [ "$is_otel_file" -eq 0 ]; then
  exit 0
fi

WARNINGS=0
SEVERE=0
SEVERE_MSGS=""

# severe: an unambiguous, deterministic violation with a known fix (Rules 1-4, 8). Shown on
# stdout like any warning; additionally captured so strict mode can hard-block on it (exit 2,
# details on stderr). warn-only rules (5-7) keep using plain echo + WARNINGS++.
severe() {  # $1 = full message (may be multiline)
  printf '%s\n' "$1"
  SEVERE_MSGS="${SEVERE_MSGS}${1}
"
  SEVERE=$((SEVERE + 1))
  WARNINGS=$((WARNINGS + 1))
}

# --- Language-aware attribute-setter call spellings (#138 gate 2) --------------------------------
# nodejs/java: span.setAttribute(  |  python/ruby: span.set_attribute(  |  dotnet: activity.SetTag(
# / .AddTag(  |  go: attribute.String(/.Int(/.Int64(/.Float64(/.Bool(/.*Slice( — go's API builds a
# KeyValue via the attribute package rather than passing the key straight to a span-attribute
# setter, so the "setter" IS that constructor call.
ATTR_SETTER_GENERAL='(setAttribute|set_attribute|SetTag|AddTag)\('
# Rules 5/7 add Go's attribute-builder pattern. Rule 1 deliberately does NOT: Go's resource
# construction (resource.WithAttributes(attribute.String(...))) uses the exact same
# attribute.String(...) call as span-attribute construction, so there is no way for a regex to
# tell the correct (resource) use from the wrong (span) one in Go — including it in Rule 1 (a
# SEVERE, strict-mode-blocking rule) would false-block legitimate Go resource setup. Go is not
# covered by Rule 1 as a result; every other language IS, since none of their resource-construction
# APIs go through this same call shape (they use an object/dict literal or a dedicated
# `.AddService(...)`-style helper instead).
ATTR_SETTER_WITH_GO='(setAttribute|set_attribute|SetTag|AddTag|attribute\.(String|Int64?|Float64|Bool|StringSlice|Int64Slice|Float64Slice|BoolSlice))\('

# Rule 1 (severe): service.name / service.version / service.namespace / service.instance.id as a
# span attribute (must be a Resource attribute instead). See the ATTR_SETTER_GENERAL comment above
# for why Go is not checked by this rule.
if echo "$CONTENT" | grep -qE "${ATTR_SETTER_GENERAL}['\"]service\.(name|version|namespace|instance)"; then
  severe "⚠ otel-lint [$FILE_PATH]: service.name / service.version / service.namespace must be Resource attributes, not span attributes.
  → Move to Resource({ [ATTR_SERVICE_NAME]: '...' }) in SDK initialization."
fi

# Rule 2 (severe): deprecated http.method. Bare-literal match (not gated on a setter call) — there
# is no legitimate use of the OLD name in any position, so this is already language-independent.
if echo "$CONTENT" | grep -qE "['\"]http\.method['\"]"; then
  severe "⚠ otel-lint [$FILE_PATH]: 'http.method' is deprecated since semconv 1.23.
  → Replace with 'http.request.method'."
fi

# Rule 3 (severe): deprecated http.url
if echo "$CONTENT" | grep -qE "['\"]http\.url['\"]"; then
  severe "⚠ otel-lint [$FILE_PATH]: 'http.url' is deprecated since semconv 1.23.
  → Replace with 'url.full'."
fi

# Rule 4 (severe): deprecated http.status_code
if echo "$CONTENT" | grep -qE "['\"]http\.status_code['\"]"; then
  severe "⚠ otel-lint [$FILE_PATH]: 'http.status_code' is deprecated since semconv 1.23.
  → Replace with 'http.response.status_code'."
fi

# Rule 5: Custom attribute without namespace prefix.
# Heuristic: an attribute-setter call with a single-word or camelCase key (no dots).
if echo "$CONTENT" | grep -qE "${ATTR_SETTER_WITH_GO}['\"][a-zA-Z][a-zA-Z0-9]*['\"]"; then
  # Exclude known valid single-segment keys (standard span/event keys, not custom business attrs)
  NON_NAMESPACED=$(echo "$CONTENT" | grep -oE "${ATTR_SETTER_WITH_GO}['\"][a-zA-Z][a-zA-Z0-9]*['\"]" | \
    grep -oE "['\"][a-zA-Z][a-zA-Z0-9]*['\"]$" | \
    grep -vE "^['\"](id|name|error|exception|event|type|status|code|message|level|kind)['\"]$" || true)
  if [ -n "$NON_NAMESPACED" ]; then
    echo "⚠ otel-lint [$FILE_PATH]: Custom attribute(s) may be missing a namespace prefix."
    echo "  → Custom attributes must use reverse-DNS prefix (e.g. com.myorg.order.id)."
    echo "  → Found: $(echo "$NON_NAMESPACED" | head -3 | tr '\n' ' ')"
    WARNINGS=$((WARNINGS+1))
  fi
fi

# Rule 6: (Simple, not Batch) span processor in non-test file. SimpleSpanProcessor is the spelling
# in nodejs/python/java/go/ruby; .NET's equivalent class is SimpleActivityExportProcessor.
if echo "$CONTENT" | grep -qE "SimpleSpanProcessor|SimpleActivityExportProcessor" && ! echo "$FILE_PATH" | grep -qE "test|spec|fixture"; then
  echo "⚠ otel-lint [$FILE_PATH]: a per-span (Simple) export processor is not recommended for production."
  echo "  → Replace with the batched processor (BatchSpanProcessor / BatchActivityExportProcessor)."
  WARNINGS=$((WARNINGS+1))
fi

# --- Canonical high-cardinality identifiers (#138 gate 4) -----------------------------------------
# Read the dotted-form list from semconv-discipline (single source of truth, same pattern this
# hook already uses for SEMCONV_VERSION) instead of hardcoding a second copy that can drift. Falls
# back to a hardcoded default if the skill's anchor text moves or the file is unreadable.
DOTTED_HIGH_CARD=$(grep -A2 "hook's extraction depends on its shape" "$SEMCONV_SKILL" 2>/dev/null | \
  tail -1 | grep -oE '`[a-z_]+\.[a-z_]+`' | tr -d '`' || true)
if [ -z "$DOTTED_HIGH_CARD" ]; then
  DOTTED_HIGH_CARD="user.id
session.id
request.id
order.id"
fi
# The same identifiers' common sloppy camelCase/snake_case spellings — code that uses the JS/Python
# variable name as the attribute KEY itself, instead of the dotted semconv form. Not derivable from
# the dotted list mechanically (capitalization is per-word), so paired by hand; keep in sync with
# DOTTED_HIGH_CARD's source above when adding an identifier.
CAMEL_SNAKE_HIGH_CARD=("userId" "user_id" "orderId" "order_id" "sessionId" "session_id" "requestId" "request_id")

HIGH_CARD_PATTERNS=()
while IFS= read -r line; do
  [ -n "$line" ] && HIGH_CARD_PATTERNS+=("$line")
done <<< "$DOTTED_HIGH_CARD"
HIGH_CARD_PATTERNS+=("${CAMEL_SNAKE_HIGH_CARD[@]}")

# Rule 7 (warning): high-cardinality identifier as a SPAN attribute. Ingest/index cost only,
# bounded by sampling and span retention — see the cardinality-position table in semconv-discipline
# for why this is a lower tier than Rule 8 (a metric dimension), not the same finding.
for attr in "${HIGH_CARD_PATTERNS[@]}"; do
  escaped_attr=$(printf '%s' "$attr" | sed 's/\./\\./g')
  if echo "$CONTENT" | grep -qE "${ATTR_SETTER_WITH_GO}['\"]${escaped_attr}['\"]"; then
    echo "⚠ otel-lint [$FILE_PATH]: High-cardinality attribute '$attr' detected as a span attribute."
    echo "  → Move to span events or structured logs. Or scope to a category (e.g. order.type)."
    WARNINGS=$((WARNINGS+1))
  fi
done

# --- Rule 8 (severe, #138 gate 3): high-cardinality identifier as a METRIC dimension -------------
# One permanently-retained time series per distinct value; sampling never touches it, and the
# series persists in the backend even after the code is fixed — semconv-discipline ranks this
# `error`, not `warning`, and the remediation differs (remove the tag, not "move it").
#
# Scope, stated plainly: this catches the LITERAL-attribute-name case only — a quoted
# high-cardinality key passed near an instrument's Add/Record call. It cannot resolve a symbolic
# constant to its string value (e.g. a C# `KeyValuePair<string, object?>(BotSemanticAttributes.UserId,
# userId)`, where the key is a named constant, not an inline literal). That needs real static
# analysis or LLM judgment — exactly what /otel-evaluate's brownfield-auditor is for, and exactly
# how it caught that case when this hook could not. Gated on an instrument CONSTRUCTOR appearing
# somewhere in the file, so an unrelated .Add()/.Record() call in a non-metrics file cannot fire it.
INSTRUMENT_CTOR_PATTERN='(createCounter|create_counter|CreateCounter|counterBuilder|createHistogram|create_histogram|CreateHistogram|histogramBuilder|createUpDownCounter|create_up_down_counter|CreateUpDownCounter)\('
if echo "$CONTENT" | grep -qE "$INSTRUMENT_CTOR_PATTERN"; then
  MUTATE_WINDOW=$(echo "$CONTENT" | grep -B1 -A3 -E '\.(Add|add|Record|record)\(' || true)
  for attr in "${HIGH_CARD_PATTERNS[@]}"; do
    escaped_attr=$(printf '%s' "$attr" | sed 's/\./\\./g')
    if echo "$MUTATE_WINDOW" | grep -qE "['\"]${escaped_attr}['\"]"; then
      severe "⚠ otel-lint [$FILE_PATH]: high-cardinality attribute '$attr' used as a METRIC dimension (counter/histogram tag).
  → Remove the tag entirely. Unlike a span attribute, a metric dimension cannot be cleaned up after the fact: it is one permanently-retained time series per distinct value, unaffected by sampling."
    fi
  done
fi

if [ "$WARNINGS" -gt 0 ]; then
  echo ""
  echo "  $WARNINGS semconv warning(s) — review before committing. (otel-as-code lint, semconv $SEMCONV_VERSION)"
fi

# Strict mode: hard-block on severe violations. Exit 2 with the severe details on stderr so
# Claude Code feeds them back as must-fix (the write already happened — PostToolUse). Warn-only
# violations never block; default (non-strict) mode always exits 0, unchanged.
if [ "$STRICT" -eq 1 ] && [ "$SEVERE" -gt 0 ]; then
  {
    echo "otel-as-code semconv-lint (strict): $SEVERE severe violation(s) must be fixed before proceeding:"
    printf '%s' "$SEVERE_MSGS"
  } >&2
  exit 2
fi

exit 0  # Advisory (default), or strict with no severe violations
