#!/usr/bin/env bash
# tests/hooks/write-context-helper.test.sh
# Locks #211: scripts/write_context.py takes over writing .claude/otel-context.json so a command
# never has to transcribe the scanner's ~10 KB JSON response by hand. Exercises the real script
# against constructed inputs -- both the success path and every refusal path -- rather than
# grepping prose, since the thing under test is actual script behavior.
set -uo pipefail
cd "$(dirname "$0")/../.."
pass=0; fail=0
check() { if eval "$2"; then echo "PASS: $1"; pass=$((pass+1)); else echo "FAIL: $1"; fail=$((fail+1)); fi; }

SCRIPT="scripts/write_context.py"
TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
REAL_VERSION="$(python3 -c "import json; print(json.load(open('.claude-plugin/plugin.json'))['version'])")"

make_json() {
  # make_json <scannedAt> <pluginVersion> <businessAttrsJson> <servicesJson>
  python3 -c "
import json, sys
print(json.dumps({
    'schemaVersion': '1.0',
    'scannedAt': sys.argv[1],
    'pluginVersion': sys.argv[2],
    'businessAttrs': json.loads(sys.argv[3]),
    'services': json.loads(sys.argv[4]),
}))
" "$1" "$2" "$3" "$4"
}

check "script file exists and is referenced by /otel-init Step 4" \
  'test -f "$SCRIPT" && grep -qF "scripts/write_context.py" commands/otel-init.md'

check "every command that refreshes the cache cross-references write_context.py, not a bare write" \
  'for f in commands/otel-instrument.md commands/otel-evaluate.md commands/otel-backend.md \
            commands/otel-collector.md commands/otel-business-attrs.md commands/otel-remediate.md \
            commands/otel-uninstrument.md; do
     grep -qF "scripts/write_context.py" "$f" || exit 1
   done'

# --- success path ---
make_json "$NOW" "$REAL_VERSION" '["order.id"]' '[{"id":"svc1","name":"checkout-api"}]' > "$TMPD/good.json"
check "valid input with no existing cache writes successfully" \
  'python3 "$SCRIPT" --output "$TMPD/out1.json" --plugin-root "$(pwd)" < "$TMPD/good.json" \
     && test -f "$TMPD/out1.json"'

check "written file round-trips the same services" \
  'python3 -c "import json; d=json.load(open(\"$TMPD/out1.json\")); assert d[\"services\"][0][\"id\"]==\"svc1\""'

# --- schema shape ---
check "missing services key is refused, nothing written" \
  '! (echo "{\"schemaVersion\":\"1.0\"}" | python3 "$SCRIPT" --output "$TMPD/out2.json") \
     && test ! -f "$TMPD/out2.json"'

check "invalid JSON on stdin is refused, nothing written" \
  '! (echo "not json" | python3 "$SCRIPT" --output "$TMPD/out3.json") \
     && test ! -f "$TMPD/out3.json"'

# --- scannedAt / pluginVersion real-value checks (#177, #202) ---
MIDNIGHT="$(date -u +%Y-%m-%d)T00:00:00Z"
make_json "$MIDNIGHT" "$REAL_VERSION" '[]' '[]' > "$TMPD/bad_time.json"
check "a midnight-exactly scannedAt is refused as an invented timestamp" \
  '! (python3 "$SCRIPT" --output "$TMPD/out4.json" < "$TMPD/bad_time.json")'

make_json "$NOW" "0.0.0" '[]' '[]' > "$TMPD/stale_version.json"
check "pluginVersion mismatched against the real plugin.json is refused" \
  '! (python3 "$SCRIPT" --output "$TMPD/out5.json" --plugin-root "$(pwd)" < "$TMPD/stale_version.json")'

check "pluginVersion is not checked when --plugin-root is omitted" \
  'python3 "$SCRIPT" --output "$TMPD/out6.json" < "$TMPD/stale_version.json"'

# --- cache ownership contract: user-owned fields must never be silently emptied (#211) ---
make_json "$NOW" "$REAL_VERSION" '["order.id"]' '[{"id":"svc1","name":"checkout-api"}]' > "$TMPD/existing_attrs.json"
make_json "$NOW" "$REAL_VERSION" '[]' '[{"id":"svc1","name":"checkout-api"}]' > "$TMPD/empty_attrs.json"
make_json "$NOW" "$REAL_VERSION" '["order.id"]' '[{"id":"svc1","name":"checkout-api"}]' > "$TMPD/carried_attrs.json"

check "a refresh that would empty top-level businessAttrs is refused" \
  '! (python3 "$SCRIPT" --output "$TMPD/out7.json" --existing "$TMPD/existing_attrs.json" \
       --plugin-root "$(pwd)" < "$TMPD/empty_attrs.json") \
     && test ! -f "$TMPD/out7.json"'

check "the same refresh succeeds once businessAttrs is carried over (merge, not replace)" \
  'python3 "$SCRIPT" --output "$TMPD/out8.json" --existing "$TMPD/existing_attrs.json" \
     --plugin-root "$(pwd)" < "$TMPD/carried_attrs.json"'

python3 -c "
import json
d = json.load(open('$TMPD/existing_attrs.json'))
d['services'][0]['scopeOverride'] = 'out'
json.dump(d, open('$TMPD/existing_scope.json', 'w'))
"
check "a refresh that would drop a service's scopeOverride (#207) is refused" \
  '! (python3 "$SCRIPT" --output "$TMPD/out9.json" --existing "$TMPD/existing_scope.json" \
       --plugin-root "$(pwd)" < "$TMPD/existing_attrs.json")'

# --- #164: services going from non-empty to empty ---
make_json "$NOW" "$REAL_VERSION" '["order.id"]' '[]' > "$TMPD/empty_services.json"

check "services going from non-empty to empty is refused by default (#164)" \
  '! (python3 "$SCRIPT" --output "$TMPD/out10.json" --existing "$TMPD/existing_attrs.json" \
       --plugin-root "$(pwd)" < "$TMPD/empty_services.json") \
     && test ! -f "$TMPD/out10.json"'

check "--allow-empty-services overrides the #164 refusal" \
  'python3 "$SCRIPT" --output "$TMPD/out11.json" --existing "$TMPD/existing_attrs.json" \
     --plugin-root "$(pwd)" --allow-empty-services < "$TMPD/empty_services.json"'

echo
echo "write-context-helper: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
