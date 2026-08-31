#!/usr/bin/env bash
# hooks/write-guard.sh
# PreToolUse hook — blocks destructive overwrites of existing OTel bootstrap files.
# Exit 0 = allow the tool call. Exit 2 = BLOCK the tool call (reason written to stderr).
# IMPORTANT: in Claude Code a PreToolUse hook blocks ONLY on exit 2. Exit 1 (or any other
# non-zero) is a non-blocking error — the tool call PROCEEDS — so a block MUST use exit 2.
# (Ref: code.claude.com/docs/en/hooks-guide — exit codes.)
# Input: JSON on stdin with the Claude Code PreToolUse shape:
#   {"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"..."}}

set -euo pipefail

# Protected files the plugin generates and must not silently overwrite:
#   tracing.{js,ts,py,go}, opentelemetry.{js,ts}, telemetry.{js,py}  — matched by basename
#   otel-java.env (generated Java agent config)                       — matched by basename
#   otelcol-agent.yaml, otelcol-gateway.yaml                          — matched by basename
#   <…>/observability/<vendor>/{main,variables,outputs}.tf           — matched by path
# (Terraform files are scoped to an observability module dir so unrelated main.tf /
#  variables.tf / outputs.tf elsewhere in the repo are never blocked.)

# Global force override via env var (manual use / CI). Per-file --force is handled below
# via the .claude/.otel-force sentinel so a slash-command flag can reach this hook process.
if [ "${OTEL_FORCE:-0}" = "1" ]; then
  exit 0
fi

# Resolve a JSON parser once. Parsing the payload needs python3 (jq is not assumed available).
# If none is present we cannot tell whether this write hits a protected file, so we FAIL CLOSED
# (block) rather than silently allowing the overwrite — loud-and-safe beats silent-and-unsafe.
# OTEL_HOOK_PYTHON overrides the interpreter path (the tests set it empty to simulate absence).
PY="${OTEL_HOOK_PYTHON-$(command -v python3 || command -v python || true)}"
if [ -z "$PY" ]; then
  echo "otel-as-code write-guard: no python3 on PATH — cannot verify this write; blocking (fail closed). Install python3." >&2
  exit 2
fi

# Read JSON from stdin
INPUT=$(cat)

# Extract tool name and file path (portable; avoids jq dependency)
TOOL=$(echo "$INPUT" | "$PY" -c "import sys,json; d=json.load(sys.stdin); print(d.get('tool_name',''))" 2>/dev/null || echo "")
FILE_PATH=$(echo "$INPUT" | "$PY" -c "import sys,json; d=json.load(sys.stdin); print(d.get('tool_input',{}).get('file_path',''))" 2>/dev/null || echo "")

# Only guard Write and Edit tools
if [ "$TOOL" != "Write" ] && [ "$TOOL" != "Edit" ]; then
  exit 0
fi

# If no file path, allow
if [ -z "$FILE_PATH" ]; then
  exit 0
fi

# Confirm-before-write enforcement for business attributes. Business semantics are never
# assumed: any business attribute written to the context cache must carry "confirmed": true
# (set by /otel-business-attrs only after explicit user approval). Block otherwise — this
# turns the confirmation gate into a structural invariant rather than prose. Full-file Writes
# are validated; Edits that don't carry full JSON content can't be checked and pass through.
case "$FILE_PATH" in
  */.claude/otel-context.json|.claude/otel-context.json)
    CONTENT=$(echo "$INPUT" | "$PY" -c "import sys,json; d=json.load(sys.stdin); print(d.get('tool_input',{}).get('content',''))" 2>/dev/null || echo "")
    if [ -n "$CONTENT" ]; then
      UNCONFIRMED=$(printf '%s' "$CONTENT" | "$PY" -c "
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)  # not full-file JSON (e.g. an Edit) — cannot validate, allow
attrs = d.get('businessAttrs', []) or []
print('\n'.join(a.get('name', '?') for a in attrs if isinstance(a, dict) and a.get('confirmed') is not True))
" 2>/dev/null || echo "")
      if [ -n "$UNCONFIRMED" ]; then
        echo "otel-as-code write-guard: refusing to write unconfirmed business attribute(s) to otel-context.json:" >&2
        printf '%s\n' "$UNCONFIRMED" | sed 's/^/  - /' >&2
        echo "Business attributes require explicit approval (\"confirmed\": true) before write." >&2
        echo "Re-run /otel-business-attrs and approve each attribute." >&2
        exit 2
      fi
    fi
    ;;
esac

# Check if the file exists on disk
if [ ! -f "$FILE_PATH" ]; then
  exit 0  # File doesn't exist yet — new write is always allowed
fi

# Path-scoped --force: when a /otel-* command is invoked with --force it writes the absolute
# paths it intends to overwrite into .claude/.otel-force (one per line) and removes the file
# afterwards. Honor it only for the listed paths, so --force never blanket-disables the guard.
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
FORCE_FILE="$PROJECT_DIR/.claude/.otel-force"
if [ -f "$FORCE_FILE" ] && grep -Fxq "$FILE_PATH" "$FORCE_FILE" 2>/dev/null; then
  exit 0
fi

# Determine whether this file is protected.
BASENAME=$(basename "$FILE_PATH")
blocked=0
case "$BASENAME" in
  tracing.js|tracing.ts|tracing.py|tracing.go|opentelemetry.js|opentelemetry.ts|telemetry.js|telemetry.py|otel-java.env|otelcol-agent.yaml|otelcol-gateway.yaml)
    blocked=1 ;;
esac
case "$FILE_PATH" in
  */observability/*/main.tf|*/observability/*/variables.tf|*/observability/*/outputs.tf)
    blocked=1 ;;
esac

if [ "$blocked" -eq 1 ]; then
  echo "otel-as-code write-guard: blocking overwrite of existing OTel file: $FILE_PATH" >&2
  echo "Re-run the originating /otel-* command with --force to overwrite." >&2
  exit 2
fi

exit 0
