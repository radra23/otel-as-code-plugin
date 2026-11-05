#!/usr/bin/env bash
# tests/hooks/messaging-operation-type.test.sh
# Locks #223: semconv-discipline listed messaging.operation.type's enum values as publish,
# receive, process -- stale against the registry at the pinned SEMCONV_VERSION, which defines
# create, send, receive, process, settle (publish deprecated -> send; deliver deprecated ->
# process; deliver was never listed at all). Verified directly against the upstream registry at
# the pinned tag (model/messaging/registry.yaml), not from memory.
#
# Also guards the issue's own suggested fix, which doesn't fit: scripts/drift_check.py's
# OLD->NEW table checker (semconv_table_entries / semconv_lookup) treats both table cells as
# attribute KEY names and looks each up as a top-level registry attribute. publish/send/deliver/
# process are enum VALUES of the single attribute messaging.operation.type, not attribute keys --
# a table row for them would not verify what it looks like it verifies (or would silently never
# match the attribute-token regex at all, since there's no dot). So this value-level deprecation
# belongs in prose, not in that table.
set -uo pipefail
cd "$(dirname "$0")/../.."
pass=0; fail=0
check() { if eval "$2"; then echo "PASS: $1"; pass=$((pass+1)); else echo "FAIL: $1"; fail=$((fail+1)); fi; }

SKILL="skills/semconv-discipline/SKILL.md"

check "lists all five current (non-deprecated) enum values" \
  'grep -qF "\`create\`, \`send\`, \`receive\`, \`process\`, \`settle\`" "$SKILL"'

check "no longer lists the stale three-value set as if it were complete" \
  '! grep -qF "\`messaging.operation.type\` — \`publish\`, \`receive\`, \`process\`" "$SKILL"'

check "notes publish is deprecated in favor of send" \
  'grep -qF "\`publish\` → use \`send\` instead" "$SKILL"'

check "notes deliver is deprecated in favor of process" \
  'grep -qF "\`deliver\` → use \`process\` instead" "$SKILL"'

check "explains why this does not belong in the OLD->NEW attribute-rename table" \
  'grep -qF "not belong in the OLD" "$SKILL" && grep -qF "not attribute names" "$SKILL"'

check "teeth: publish/send/deliver/process were NOT added as a markdown table row drift_check would parse" \
  'python3 -c "
import re
rows = []
for line in open(\"$SKILL\"):
    if not line.startswith(\"|\") or \"---\" in line:
        continue
    cells = [c.strip() for c in line.strip().strip(\"|\").split(\"|\")]
    rows.append(cells)
for cells in rows:
    joined = \" \".join(cells)
    assert \"publish\" not in joined or \"operation.type\" not in joined, f\"found in table row: {cells}\"
print(\"ok\")
"'

echo
echo "messaging-operation-type: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
