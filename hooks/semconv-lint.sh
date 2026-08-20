#!/usr/bin/env bash
# hooks/semconv-lint.sh
# PostToolUse hook — advisory semconv lint on OTel file writes.
# Always exits 0 (advisory only). Writes warnings to stdout for Claude to display.

set -euo pipefail

# Resolve the pinned semconv version from its single source of truth (the semconv-discipline
# skill) instead of hardcoding it here. Falls back to "unknown" if the skill can't be read.
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SEMCONV_VERSION=$(grep -oE 'SEMCONV_VERSION:[[:space:]]*[0-9]+\.[0-9]+\.[0-9]+' \
  "$PLUGIN_ROOT/skills/semconv-discipline/SKILL.md" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
SEMCONV_VERSION="${SEMCONV_VERSION:-unknown}"

INPUT=$(cat)

# Extract file path written
FILE_PATH=$(echo "$INPUT" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('tool_input', {}).get('file_path', ''))
" 2>/dev/null || echo "")

# Only lint OTel-related files
OTEL_PATTERNS=("tracing" "telemetry" "instrumentation" "opentelemetry")
is_otel_file=0
BASENAME=$(basename "$FILE_PATH" 2>/dev/null || echo "")
BASENAME_LOWER=$(echo "$BASENAME" | tr '[:upper:]' '[:lower:]')

for pat in "${OTEL_PATTERNS[@]}"; do
  if [[ "$BASENAME_LOWER" == *"$pat"* ]]; then
    is_otel_file=1
    break
  fi
done

if [ "$is_otel_file" -eq 0 ] || [ ! -f "$FILE_PATH" ]; then
  exit 0
fi

WARNINGS=0
CONTENT=$(cat "$FILE_PATH" 2>/dev/null || echo "")

# Rule 1: service.name / service.version / service.namespace as span attribute
if echo "$CONTENT" | grep -qE "setAttribute\(['\"]service\.(name|version|namespace|instance)"; then
  echo "⚠ otel-lint [$FILE_PATH]: service.name / service.version / service.namespace must be Resource attributes, not span attributes."
  echo "  → Move to Resource({ [ATTR_SERVICE_NAME]: '...' }) in SDK initialization."
  WARNINGS=$((WARNINGS+1))
fi

# Rule 2: deprecated http.method
if echo "$CONTENT" | grep -qE "setAttribute\(['\"]http\.method['\"]|['\"]http\.method['\"]"; then
  echo "⚠ otel-lint [$FILE_PATH]: 'http.method' is deprecated since semconv 1.23."
  echo "  → Replace with 'http.request.method'."
  WARNINGS=$((WARNINGS+1))
fi

# Rule 3: deprecated http.url
if echo "$CONTENT" | grep -qE "['\"]http\.url['\"]"; then
  echo "⚠ otel-lint [$FILE_PATH]: 'http.url' is deprecated since semconv 1.23."
  echo "  → Replace with 'url.full'."
  WARNINGS=$((WARNINGS+1))
fi

# Rule 4: deprecated http.status_code
if echo "$CONTENT" | grep -qE "['\"]http\.status_code['\"]"; then
  echo "⚠ otel-lint [$FILE_PATH]: 'http.status_code' is deprecated since semconv 1.23."
  echo "  → Replace with 'http.response.status_code'."
  WARNINGS=$((WARNINGS+1))
fi

# Rule 5: Custom attribute without namespace prefix
# Heuristic: setAttribute call with a single-word or camelCase key (no dots)
if echo "$CONTENT" | grep -qE "setAttribute\(['\"][a-zA-Z][a-zA-Z0-9]*['\"]"; then
  # Exclude known valid single-segment keys (standard span/event keys, not custom business attrs)
  NON_NAMESPACED=$(echo "$CONTENT" | grep -oE "setAttribute\(['\"][a-zA-Z][a-zA-Z0-9]*['\"]" | \
    grep -vE "setAttribute\(['\"](id|name|error|exception|event|type|status|code|message|level|kind)['\"]" || true)
  if [ -n "$NON_NAMESPACED" ]; then
    echo "⚠ otel-lint [$FILE_PATH]: Custom attribute(s) may be missing a namespace prefix."
    echo "  → Custom attributes must use reverse-DNS prefix (e.g. com.myorg.order.id)."
    echo "  → Found: $(echo "$NON_NAMESPACED" | head -3 | tr '\n' ' ')"
    WARNINGS=$((WARNINGS+1))
  fi
fi

# Rule 6: SimpleSpanProcessor in non-test file
if echo "$CONTENT" | grep -qE "SimpleSpanProcessor" && ! echo "$FILE_PATH" | grep -qE "test|spec|fixture"; then
  echo "⚠ otel-lint [$FILE_PATH]: SimpleSpanProcessor is not recommended for production."
  echo "  → Replace with BatchSpanProcessor."
  WARNINGS=$((WARNINGS+1))
fi

# Rule 7: High-cardinality attribute names
HIGH_CARD_PATTERNS=("userId" "user_id" "orderId" "order_id" "sessionId" "session_id" "requestId" "request_id")
for attr in "${HIGH_CARD_PATTERNS[@]}"; do
  if echo "$CONTENT" | grep -qE "setAttribute\(['\"]${attr}['\"]"; then
    echo "⚠ otel-lint [$FILE_PATH]: High-cardinality attribute '$attr' detected."
    echo "  → Move to span events or structured logs. Or scope to a category (e.g. order.type)."
    WARNINGS=$((WARNINGS+1))
  fi
done

if [ "$WARNINGS" -gt 0 ]; then
  echo ""
  echo "  $WARNINGS semconv warning(s) — review before committing. (otel-as-code lint, semconv $SEMCONV_VERSION)"
fi

exit 0  # Always advisory
