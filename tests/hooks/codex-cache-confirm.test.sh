#!/usr/bin/env bash
# tests/hooks/codex-cache-confirm.test.sh
# Codex writes to the context cache get the business-attribute confirmation check (#254). Before
# this, the Codex PreToolUse adapter gave write-guard full content only for "*** Add File" hunks,
# so an Update, a Move, or a direct Edit that set "confirmed": false went through.
#
# The check stays in one place, hooks/otel-context-check.py (run by write-guard.sh). A patch can't
# be judged without rebuilding its result, which would mean a second parser that can disagree with
# apply_patch (three review rounds found such differences), so a patch that could reach the cache
# is allowed only as one full-file Add; every other way of reaching it is denied. After a patch
# lands, post-tool-use.py checks the real file again. Payloads are the real Codex hook shape.
set -uo pipefail
cd "$(dirname "$0")/../.."
ROOT=$(pwd)
PRE="$ROOT/hooks/codex/pre-tool-use.py"
POST="$ROOT/hooks/codex/post-tool-use.py"
PASS=0; FAIL=0
check() { if eval "$2"; then echo "PASS: $1"; PASS=$((PASS+1)); else echo "FAIL: $1"; FAIL=$((FAIL+1)); fi; }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

codex_payload() {  # event, cwd, tool_name, tool_input JSON
  python3 -c 'import json,sys; print(json.dumps({"session_id":"s","turn_id":"t","transcript_path":None,"cwd":sys.argv[2],"hook_event_name":sys.argv[1],"model":"gpt-5","permission_mode":"default","tool_name":sys.argv[3],"tool_use_id":"call_1","tool_input":json.loads(sys.argv[4])}))' "$@"
}
patch_input() { python3 -c 'import json,sys; print(json.dumps({"command":sys.argv[1]}))' "$1"; }
fresh() {  # a project whose cache holds two confirmed attributes, laid out as /otel-business-attrs writes it
  rm -rf "$T/p"; mkdir -p "$T/p/.claude"
  cat > "$T/p/.claude/otel-context.json" <<'JSON'
{
  "schemaVersion": "2",
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
pre_patch() { OUT=$(codex_payload PreToolUse "$T/p" apply_patch "$(patch_input "$1")" | python3 "$PRE"); }
denied() { echo "$OUT" | grep -q '"permissionDecision": "deny"'; }
points_to_helper() { echo "$OUT" | grep -q "write_context.py"; }
FLIP=$'@@\n     {\n       "name": "biz.checkout.value",\n-      "confirmed": true\n+      "confirmed": false\n     },'
add_lines() {  # the fresh cache as "+" lines, first attribute's confirmed set to $1
  python3 -c 'import sys; t=open(sys.argv[1]).read().replace("\"confirmed\": true", "\"confirmed\": "+sys.argv[2], 1); print("\n".join("+"+l for l in t.splitlines()))' "$T/p/.claude/otel-context.json" "$1"
}

# --- Patches that reach the cache other than as one full-file Add: denied, pointing at the helper.
fresh; pre_patch $'*** Begin Patch\n*** Update File: .claude/otel-context.json\n'"$FLIP"$'\n*** End Patch'
check "Update setting confirmed:false on the cache is denied" 'denied && points_to_helper'

fresh; pre_patch $'*** Begin Patch\n*** Update File: .claude/otel-context.json\n@@\n-  "schemaVersion": "2",\n+  "schemaVersion": "3",\n*** End Patch'
check "even a harmless Update of the cache is denied (a diff can't be checked)" 'denied && points_to_helper'

fresh; cp "$T/p/.claude/otel-context.json" "$T/p/.claude/draft.json"
pre_patch $'*** Begin Patch\n*** Update File: .claude/draft.json\n*** Move to: .claude/otel-context.json\n'"$FLIP"$'\n*** End Patch'
check "Update moved onto the cache is denied" 'denied'

fresh; pre_patch $'*** Begin Patch\n*** Delete File: .claude/otel-context.json\n*** End Patch'
check "Delete of the cache is denied" 'denied'

fresh; pre_patch $'*** Begin Patch\n  *** Update File: .claude/otel-context.json  \n'"$FLIP"$'\n*** End Patch'
check "an indented Update header on the cache is denied" 'denied'

fresh; echo "hello" > "$T/p/notes.txt"
pre_patch $'*** Begin Patch\n*** Update File: notes.txt\n@@\n hello\n *** Update File: .claude/otel-context.json\n*** End Patch'
check "a header-like line inside a hunk that names the cache is denied (read either way)" 'denied'

fresh; ln -s otel-context.json "$T/p/.claude/ctx-link.json"
pre_patch $'*** Begin Patch\n*** Update File: .claude/ctx-link.json\n'"$FLIP"$'\n*** End Patch'
check "an Update through a symlink to the cache is denied" 'denied'

fresh; ln "$T/p/.claude/otel-context.json" "$T/p/.claude/ctx-hard.json"
pre_patch $'*** Begin Patch\n*** Update File: .claude/ctx-hard.json\n'"$FLIP"$'\n*** End Patch'
check "an Update through a hard link to the cache is denied" 'denied'

fresh; pre_patch $'*** Begin Patch\n*** Update File: .claude/OTEL-Context.JSON\n'"$FLIP"$'\n*** End Patch'
check "an Update of the cache in another letter case is denied" 'denied'

fresh; pre_patch "$(printf '*** Begin Patch\n*** Update File: .claude/otel\xef\xbc\x8dcontext.json\n%s\n*** End Patch' "$FLIP")"
check "an Update of the cache in a Unicode lookalike spelling (fullwidth hyphen) is denied" 'denied'

fresh; ADD=$(add_lines true)
pre_patch "*** Begin Patch
*** Add File: .claude/otel-context.json
$ADD
*** Update File: notes.txt
@@
+x
*** End Patch"
check "a full-file Add of the cache mixed with another change is denied" 'denied'

fresh; ADD=$(add_lines true)
pre_patch "*** Begin Patch
  *** Add File: .claude/otel-context.json
$ADD
*** End Patch"
check "an indented Add of the cache is denied, not read as a checked Add" 'denied'

# --- One full-file Add of the cache: its content is checked by otel-context-check.py.
fresh; check "the Add helper produces the cache as + lines" '[ "$(add_lines false | grep -c "^+")" -ge 10 ] && add_lines false | grep -q "\"confirmed\": false"'
fresh; ADD=$(add_lines false); rm "$T/p/.claude/otel-context.json"
pre_patch "*** Begin Patch
*** Add File: .claude/otel-context.json
$ADD
*** End Patch"
check "a full-file Add with an unconfirmed attribute is denied" 'denied'
check "that deny names the attribute" 'echo "$OUT" | grep -q "biz.checkout.value"'

fresh; ADD=$(add_lines true); rm "$T/p/.claude/otel-context.json"
pre_patch "*** Begin Patch
*** Add File: .claude/otel-context.json
$ADD
*** End Patch"
check "a full-file Add with every attribute confirmed is allowed" '[ -z "$OUT" ]'

fresh; ADD=$(add_lines true); rm "$T/p/.claude/otel-context.json"
pre_patch "<<'EOF'
*** Begin Patch
*** Add File: .claude/otel-context.json
$ADD
*** End Patch
EOF"
check "the same Add in a heredoc wrapper is allowed" '[ -z "$OUT" ]'

# apply_patch splits a patch on "\n" only. A U+2028 inside a line keeps it one line there, so
# the Add is judged on that one line: here it makes the file invalid JSON, which can't be checked.
fresh; rm "$T/p/.claude/otel-context.json"
pre_patch "$(printf '*** Begin Patch\n*** Add File: .claude/otel-context.json\n+{"businessAttrs": [{"name": "biz.a", "confirmed": true}\xe2\x80\xa8+, {"name": "biz.b", "confirmed": true}]}\n*** End Patch')"
check "a cache Add with a U+2028 line separator is judged as one line (invalid JSON: denied)" 'denied'

fresh; rm "$T/p/.claude/otel-context.json"
pre_patch $'*** Begin Patch\n*** Add File: .claude/otel-context.json\n+{"businessAttrs": [\n*** End Patch'
check "a cache Add that is not valid JSON is denied (it can't be checked)" 'denied'

# --- Patches that don't reach the cache are unaffected, even when their text mentions it.
fresh; echo "old" > "$T/p/README.md"
pre_patch $'*** Begin Patch\n*** Update File: README.md\n@@\n-old\n+see .claude/otel-context.json\n*** End Patch'
check "a docs edit that mentions the cache in its content is allowed" '[ -z "$OUT" ]'

# The overwrite guard reads headers the way apply_patch does, trimmed: an indented Update of a
# generated file is still an overwrite of it.
fresh; printf '// generated by otel-as-code v0.1.0\nold\n' > "$T/p/tracing.js"
pre_patch $'*** Begin Patch\n  *** Update File: tracing.js\n@@\n-old\n+new\n*** End Patch'
check "an indented Update of a generated file is still blocked by the overwrite guard" 'denied'

# --- Direct Edit/Write: passed through, so otel-context-check.py sees what Claude Code would.
fresh
OUT=$(codex_payload PreToolUse "$T/p" Edit "$(python3 -c 'import json; print(json.dumps({"file_path":".claude/otel-context.json","old_string":"\"confirmed\": true","new_string":"\"confirmed\": false"}))')" | python3 "$PRE")
check "direct Edit setting confirmed:false on the cache is denied" 'denied'
fresh
OUT=$(codex_payload PreToolUse "$T/p" Edit "$(python3 -c 'import json; print(json.dumps({"file_path":".claude/otel-context.json","old_string":"\"schemaVersion\": \"2\"","new_string":"\"schemaVersion\": \"3\""}))')" | python3 "$PRE")
check "direct Edit of another field is allowed" '[ -z "$OUT" ]'
fresh; ln -s otel-context.json "$T/p/.claude/ctx-link.json"
OUT=$(codex_payload PreToolUse "$T/p" Write "$(python3 -c 'import json; print(json.dumps({"file_path":".claude/ctx-link.json","content":"{\"businessAttrs\":[{\"name\":\"x\"}]}"}))')" | python3 "$PRE")
check "direct Write through a symlink to the cache is denied" 'denied'

# --- After a patch lands, the real file is checked again (backs up the guard; it can't undo).
fresh; python3 -c 'import sys; p=sys.argv[1]; t=open(p).read().replace("\"confirmed\": true","\"confirmed\": false",1); open(p,"w").write(t)' "$T/p/.claude/otel-context.json"
OUT=$(codex_payload PostToolUse "$T/p" apply_patch "$(patch_input $'*** Begin Patch\n*** Update File: .claude/otel-context.json\n'"$FLIP"$'\n*** End Patch')" | python3 "$POST")
check "post: an unconfirmed attribute on disk after a patch is a must-fix message" 'echo "$OUT" | grep -q "MUST FIX" && echo "$OUT" | grep -q "biz.checkout.value"'
fresh
OUT=$(codex_payload PostToolUse "$T/p" apply_patch "$(patch_input $'*** Begin Patch\n*** Update File: .claude/otel-context.json\n@@\n-  "schemaVersion": "2",\n+  "schemaVersion": "3",\n*** End Patch')" | python3 "$POST")
check "post: a cache with every attribute confirmed gets no message" '[ -z "$OUT" ]'

# --- The rule lives in one place: the adapters never read the quoted "confirmed" key themselves.
check "the Codex adapters hold no copy of the confirmation rule" '! grep -nE "[\"'"'"']confirmed[\"'"'"']" hooks/codex/*.py'

echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
