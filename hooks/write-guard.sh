#!/usr/bin/env bash
# hooks/write-guard.sh
# PreToolUse hook — blocks destructive overwrites of existing OTel bootstrap files.
# Exit 0 = allow the tool call. Exit 1 = block the tool call (write error to stderr).
# Input: JSON on stdin with the Claude Code PreToolUse shape:
#   {"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"..."}}

set -euo pipefail

# Protected files the plugin generates and must not silently overwrite:
#   <stem>.<ext> bootstraps, otel-java.env, otelcol-*.yaml  — matched by basename, from the
#     derived set in hooks/otel-paths.sh (the single source of truth for generated names)
#   <…>/observability/<vendor>/{main,variables,outputs}.tf  — matched by path
# (Terraform files are scoped to an observability module dir so unrelated main.tf /
#  variables.tf / outputs.tf elsewhere in the repo are never blocked.)

# Generated-file vocabulary, shared with session-summary.sh so the two cannot drift.
# Guarded: under `set -e` a failed source would abort with exit 1, which this hook's contract
# reads as BLOCK — bricking every Write/Edit in the repo over a broken install. An absent guard
# with a loud message is the better failure than a session where nothing can be written.
# shellcheck source=hooks/otel-paths.sh
OTEL_PATHS_LIB="$(dirname "${BASH_SOURCE[0]}")/otel-paths.sh"
if ! . "$OTEL_PATHS_LIB" 2>/dev/null; then
  echo "otel-as-code write-guard: cannot load $OTEL_PATHS_LIB — overwrite protection is OFF." >&2
  echo "Reinstall the plugin; until then generated OTel files are not protected." >&2
  exit 0
fi

# Global force override via env var (manual use / CI). Per-file --force is handled below
# via the .claude/.otel-force sentinel so a slash-command flag can reach this hook process.
if [ "${OTEL_FORCE:-0}" = "1" ]; then
  exit 0
fi

# Read JSON from stdin
INPUT=$(cat)

# Extract tool name and file path (portable; avoids jq dependency)
TOOL=$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('tool_name',''))" 2>/dev/null || echo "")
FILE_PATH=$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('tool_input',{}).get('file_path',''))" 2>/dev/null || echo "")

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
    CONTENT=$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('tool_input',{}).get('content',''))" 2>/dev/null || echo "")
    if [ -n "$CONTENT" ]; then
      UNCONFIRMED=$(printf '%s' "$CONTENT" | python3 -c "
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
        exit 1
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
#
# Both sides are normalised before comparison rather than compared as raw strings. The tool
# reports `file_path` in the host's own convention — on Windows a backslashed
# `C:\Users\me\repo\src\tracing.ts` — while the sentinel is written from a shell where the
# same file is `/c/Users/me/repo/src/tracing.ts`, and Codex's apply_patch reports paths
# relative to the session cwd. An exact-string match can never succeed across those shapes,
# which silently turned --force into a no-op. See hooks/otel-force-match.py.
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
FORCE_FILE="$PROJECT_DIR/.claude/.otel-force"
if [ -f "$FORCE_FILE" ] && python3 "$(dirname "${BASH_SOURCE[0]}")/otel-force-match.py" \
     "$FILE_PATH" "$PROJECT_DIR" "$FORCE_FILE" 2>/dev/null; then
  exit 0
fi

# Determine whether this file is protected. The basename set is derived in otel-paths.sh
# from stems x extensions, so no generated name can fall out of the guard by omission.
blocked=0
if otel_is_generated_path "$FILE_PATH"; then
  blocked=1
fi
case "$FILE_PATH" in
  */observability/*/main.tf|*/observability/*/variables.tf|*/observability/*/outputs.tf)
    blocked=1 ;;
esac

if [ "$blocked" -eq 1 ]; then
  echo "otel-as-code write-guard: blocking overwrite of existing OTel file: $FILE_PATH" >&2
  echo "Re-run the originating /otel-* command with --force to overwrite." >&2
  exit 1
fi

exit 0
