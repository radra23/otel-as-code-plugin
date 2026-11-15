#!/usr/bin/env bash
# tests/hooks/codex-cache-confirm.test.sh
# Codex writes to the context cache get the same business-attribute confirmation check as Claude
# Code (#254). Before this, the Codex PreToolUse adapter handed write-guard full content only for
# "*** Add File" hunks; an "*** Update File" hunk, or a direct Edit, reached it as a contentless
# Write, so a patch that set "confirmed": false went through. The check itself must stay in one
# place (hooks/otel-context-check.py, run by write-guard.sh): the adapter only rebuilds the file as
# the patch would leave it. Payloads are the real Codex PreToolUse shape.
set -uo pipefail
cd "$(dirname "$0")/../.."
ROOT=$(pwd)
PRE="$ROOT/hooks/codex/pre-tool-use.py"
PASS=0; FAIL=0
check() { if eval "$2"; then echo "PASS: $1"; PASS=$((PASS+1)); else echo "FAIL: $1"; FAIL=$((FAIL+1)); fi; }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

codex_payload() {  # cwd, tool_name, tool_input JSON
  python3 -c 'import json,sys; print(json.dumps({"session_id":"s","turn_id":"t","transcript_path":None,"cwd":sys.argv[1],"hook_event_name":"PreToolUse","model":"gpt-5","permission_mode":"default","tool_name":sys.argv[2],"tool_use_id":"call_1","tool_input":json.loads(sys.argv[3])}))' "$@"
}
patch_input() { python3 -c 'import json,sys; print(json.dumps({"command":sys.argv[1]}))' "$1"; }
fresh() {  # a project whose cache holds two confirmed attributes, laid out as /otel-business-attrs writes it
  rm -rf "$T/p"; mkdir -p "$T/p/.claude"
  cat > "$T/p/.claude/otel-context.json" <<'JSON'
{
  "schemaVersion": "2",
  "service": {
    "name": "checkout-api"
  },
  "businessAttrs": [
    {
      "name": "biz.checkout.value",
      "confirmed": true
    },
    {
      "name": "biz.checkout.items",
      "confirmed": true
    }
  ]
}
JSON
}
run_patch() {  # patch text -> OUT
  OUT=$(codex_payload "$T/p" apply_patch "$(patch_input "$1")" | python3 "$PRE")
}
denied() { echo "$OUT" | grep -q '"permissionDecision": "deny"'; }

# 1. Update hunk flipping one attribute to unconfirmed.
fresh
run_patch $'*** Begin Patch\n*** Update File: .claude/otel-context.json\n@@\n     {\n       "name": "biz.checkout.value",\n-      "confirmed": true\n+      "confirmed": false\n     },\n*** End Patch'
check "apply_patch Update setting confirmed:false on the cache is denied" 'denied'
check "the deny names the attribute" 'echo "$OUT" | grep -q "biz.checkout.value"'

# 2. Update hunk adding an unconfirmed attribute, anchored with an @@ context line.
fresh
run_patch $'*** Begin Patch\n*** Update File: .claude/otel-context.json\n@@ "businessAttrs": [\n+    {\n+      "name": "biz.checkout.coupon"\n+    },\n     {\n       "name": "biz.checkout.value",\n*** End Patch'
check "apply_patch Update adding an unconfirmed attribute is denied" 'denied'

# 3. Two hunks, both harmless: the rebuilt file must still hold every confirmed attribute.
fresh
run_patch $'*** Begin Patch\n*** Update File: .claude/otel-context.json\n@@\n-  "schemaVersion": "2",\n+  "schemaVersion": "3",\n@@\n-    "name": "checkout-api"\n+    "name": "checkout"\n*** End Patch'
check "apply_patch Update that leaves every attribute confirmed is allowed" '[ -z "$OUT" ]'

# 4. Update of another file moved onto the cache path.
fresh
cp "$T/p/.claude/otel-context.json" "$T/p/.claude/draft.json"
run_patch $'*** Begin Patch\n*** Update File: .claude/draft.json\n*** Move to: .claude/otel-context.json\n@@\n     {\n       "name": "biz.checkout.items",\n-      "confirmed": true\n+      "confirmed": false\n*** End Patch'
check "apply_patch Update moved onto the cache with an unconfirmed attribute is denied" 'denied'

# 5. An Update the adapter cannot apply to the cache: it cannot be checked, so it is not let through.
fresh
run_patch $'*** Begin Patch\n*** Update File: .claude/otel-context.json\n@@\n-  "not": "in the file"\n+  "x": 1\n*** End Patch'
check "apply_patch Update on the cache that cannot be applied is denied" 'denied'
check "that deny says the check could not run" 'echo "$OUT" | grep -qi "could not"'

# 6. The same unappliable Update on an ordinary file is not this check's business.
fresh; echo "hello" > "$T/p/notes.txt"
run_patch $'*** Begin Patch\n*** Update File: notes.txt\n@@\n-absent line\n+x\n*** End Patch'
check "an unappliable Update on an ordinary file is left to apply_patch" '[ -z "$OUT" ]'

# 7. A direct Edit (Claude-shaped tool input) setting confirmed:false.
fresh
OUT=$(codex_payload "$T/p" Edit "$(python3 -c 'import json; print(json.dumps({"file_path":".claude/otel-context.json","old_string":"\"confirmed\": true","new_string":"\"confirmed\": false"}))')" | python3 "$PRE")
check "direct Edit setting confirmed:false on the cache is denied" 'denied'

# 8. The rule lives in one place: the Codex adapters never test "confirmed" themselves.
check "the Codex adapters hold no copy of the confirmation rule" '! grep -n "confirmed" hooks/codex/*.py'

echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
