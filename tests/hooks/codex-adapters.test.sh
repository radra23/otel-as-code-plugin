#!/usr/bin/env bash
# tests/hooks/codex-adapters.test.sh
# Verify the Codex hook adapters translate Codex apply_patch payloads to the plugin's
# guardrails (reusing write-guard.sh / semconv-lint.sh) and emit Codex's output contract.
set -euo pipefail

PRE="$(cd "$(dirname "$0")/../.." && pwd)/hooks/codex/pre-tool-use.py"
POST="$(cd "$(dirname "$0")/../.." && pwd)/hooks/codex/post-tool-use.py"
PASS=0
FAIL=0

# Build a Codex hook payload (tool_name=apply_patch, patch text in tool_input.command).
payload() {  # cwd, patch
  python3 -c 'import json,sys; print(json.dumps({"hook_event_name":sys.argv[1],"tool_name":"apply_patch","cwd":sys.argv[2],"tool_input":{"command":sys.argv[3]}}))' "$1" "$2" "$3"
}

check() {  # name, expect(deny|allow|context|substr), output, [needle]
  local name="$1" expect="$2" out="$3" needle="${4:-}"
  case "$expect" in
    deny)    echo "$out" | grep -q '"permissionDecision": "deny"' && r=1 || r=0 ;;
    allow)   [ -z "$out" ] && r=1 || r=0 ;;
    context) echo "$out" | grep -q '"additionalContext"' && r=1 || r=0 ;;
    substr)  echo "$out" | grep -q "$needle" && r=1 || r=0 ;;
  esac
  if [ "$r" -eq 1 ]; then echo "PASS: $name"; PASS=$((PASS+1)); else echo "FAIL: $name"; echo "  out: $out"; FAIL=$((FAIL+1)); fi
}

# Test 1: apply_patch Update on an existing protected tracing.js -> PreToolUse deny
TMP=$(mktemp -d); echo "existing" > "$TMP/tracing.js"
PATCH=$'*** Begin Patch\n*** Update File: tracing.js\n@@\n-existing\n+changed\n*** End Patch'
OUT=$(payload PreToolUse "$TMP" "$PATCH" | python3 "$PRE")
check "pre: blocks overwrite of protected tracing.js" deny "$OUT"
rm -rf "$TMP"

# Test 2: apply_patch Add of a new, non-protected file -> allow (no output)
TMP=$(mktemp -d)
PATCH=$'*** Begin Patch\n*** Add File: src/util.js\n+console.log("hi");\n*** End Patch'
OUT=$(payload PreToolUse "$TMP" "$PATCH" | python3 "$PRE")
check "pre: allows new non-protected file" allow "$OUT"
rm -rf "$TMP"

# Test 3: apply_patch Add of otel-context.json with an UNCONFIRMED business attr -> deny
TMP=$(mktemp -d); mkdir -p "$TMP/.claude"
CTX='{"schemaVersion":"1","businessAttrs":[{"name":"biz.checkout.rate","confirmed":false}]}'
PATCH=$'*** Begin Patch\n*** Add File: .claude/otel-context.json\n+'"$CTX"$'\n*** End Patch'
OUT=$(payload PreToolUse "$TMP" "$PATCH" | python3 "$PRE")
check "pre: blocks unconfirmed business-attr write" deny "$OUT"
rm -rf "$TMP"

# Test 4: PostToolUse on an OTel file with seeded violations -> additionalContext
TMP=$(mktemp -d)
cat > "$TMP/tracing.js" <<'EOF'
span.setAttribute('service.name', 'x');
span.setAttribute('http.method', 'POST');
span.setAttribute('orderId', id);
EOF
PATCH=$'*** Begin Patch\n*** Update File: tracing.js\n@@\n+span.setAttribute("orderId", id);\n*** End Patch'
OUT=$(payload PostToolUse "$TMP" "$PATCH" | python3 "$POST")
check "post: surfaces semconv warnings as additionalContext" context "$OUT"
check "post: warning names the violation" substr "$OUT" "service.name"
rm -rf "$TMP"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
