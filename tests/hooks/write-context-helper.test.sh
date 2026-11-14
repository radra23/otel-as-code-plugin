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

# Rule 4: business attributes need "confirmed": true on every write, first scan included. The
# commands write the cache through this script, which hooks/write-guard.sh never sees.
make_json "$NOW" "$REAL_VERSION" '[{"name":"order.value","kind":"histogram","confirmed":true}]' '[{"id":"svc1","name":"checkout-api"}]' > "$TMPD/confirmed_attr.json"
make_json "$NOW" "$REAL_VERSION" '[{"name":"order.value","kind":"histogram","confirmed":true},{"name":"cart.size","kind":"gauge"}]' '[{"id":"svc1","name":"checkout-api"}]' > "$TMPD/unconfirmed_attr.json"
make_json "$NOW" "$REAL_VERSION" '[{"name":"cart.size","kind":"gauge","confirmed":"yes"}]' '[{"id":"svc1","name":"checkout-api"}]' > "$TMPD/truthy_attr.json"

check "a confirmed business attribute is written" \
  'python3 "$SCRIPT" --output "$TMPD/out_conf.json" --plugin-root "$(pwd)" < "$TMPD/confirmed_attr.json" >/dev/null \
     && test -f "$TMPD/out_conf.json"'
check "an unconfirmed business attribute is refused on a first write, and nothing is written" \
  '! (python3 "$SCRIPT" --output "$TMPD/out_unconf.json" --plugin-root "$(pwd)" < "$TMPD/unconfirmed_attr.json") 2>/dev/null \
     && test ! -f "$TMPD/out_unconf.json"'
check "the refusal names the unconfirmed attribute" \
  '{ python3 "$SCRIPT" --output "$TMPD/out_unconf2.json" --plugin-root "$(pwd)" < "$TMPD/unconfirmed_attr.json" 2>&1 || true; } | grep -q "cart.size"'
check "only a literal true counts as confirmed (\"yes\" is refused)" \
  '! (python3 "$SCRIPT" --output "$TMPD/out_truthy.json" --plugin-root "$(pwd)" < "$TMPD/truthy_attr.json") 2>/dev/null \
     && test ! -f "$TMPD/out_truthy.json"'

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

# --- critique follow-up: refuse-not-crash on I/O failures (never a traceback instead of REFUSED) ---
check "a bad --output path (nonexistent parent dir) is refused cleanly, not a traceback" \
  'OUT=$(python3 "$SCRIPT" --output "$TMPD/no/such/dir/out.json" < "$TMPD/good.json" 2>&1); \
   rc=$?; [ "$rc" -ne 0 ] && echo "$OUT" | grep -qF "REFUSED:" && ! echo "$OUT" | grep -qF "Traceback"'

mkdir -p "$TMPD/badplugin/.claude-plugin"
echo "{not valid json" > "$TMPD/badplugin/.claude-plugin/plugin.json"
check "a malformed plugin.json is refused cleanly, not a traceback" \
  'OUT=$(python3 "$SCRIPT" --output "$TMPD/out_badplugin.json" --plugin-root "$TMPD/badplugin" \
       < "$TMPD/good.json" 2>&1); rc=$?; \
   [ "$rc" -ne 0 ] && echo "$OUT" | grep -qF "REFUSED:" && ! echo "$OUT" | grep -qF "Traceback" \
   && test ! -f "$TMPD/out_badplugin.json"'

# --- cache ownership contract: conflicts[] resolution and user-added services must survive a refresh ---
python3 -c "
import json
json.dump({
    'schemaVersion': '1.0', 'scannedAt': '$NOW', 'pluginVersion': '$REAL_VERSION',
    'services': [
        {'id': 'svc1', 'name': 'checkout-api'},
        {'id': 'manual-svc', 'name': 'manual-service', 'nameSource': 'user-added'},
    ],
    'conflicts': [
        {'serviceId': 'svc1', 'attribute': 'service.name', 'sources': [],
         'resolvedValue': 'checkout-api', 'resolvedSource': 'user', 'resolvedAt': '$NOW'}
    ],
}, open('$TMPD/existing_full.json', 'w'))
"

python3 -c "
import json
d = json.load(open('$TMPD/existing_full.json'))
d['services'] = [s for s in d['services'] if s['id'] != 'manual-svc']
json.dump(d, open('$TMPD/drop_user_added.json', 'w'))
"
check "a refresh that drops a user-added service is refused" \
  '! (python3 "$SCRIPT" --output "$TMPD/out12.json" --existing "$TMPD/existing_full.json" \
       --plugin-root "$(pwd)" < "$TMPD/drop_user_added.json") \
     && test ! -f "$TMPD/out12.json"'

check "the same refresh succeeds once the user-added service is carried over" \
  'python3 "$SCRIPT" --output "$TMPD/out13.json" --existing "$TMPD/existing_full.json" \
     --plugin-root "$(pwd)" < "$TMPD/existing_full.json"'

python3 -c "
import json
d = json.load(open('$TMPD/existing_full.json'))
d['conflicts'][0]['resolvedValue'] = None
d['conflicts'][0]['resolvedSource'] = None
d['conflicts'][0]['resolvedAt'] = None
json.dump(d, open('$TMPD/reset_conflict.json', 'w'))
"
check "a refresh that resets a resolved conflict's resolvedValue is refused" \
  '! (python3 "$SCRIPT" --output "$TMPD/out14.json" --existing "$TMPD/existing_full.json" \
       --plugin-root "$(pwd)" < "$TMPD/reset_conflict.json") \
     && test ! -f "$TMPD/out14.json"'

python3 -c "
import json
d = json.load(open('$TMPD/existing_full.json'))
d['conflicts'] = []
json.dump(d, open('$TMPD/drop_conflict.json', 'w'))
"
check "a refresh that drops a resolved conflict entry entirely is refused" \
  '! (python3 "$SCRIPT" --output "$TMPD/out15.json" --existing "$TMPD/existing_full.json" \
       --plugin-root "$(pwd)" < "$TMPD/drop_conflict.json") \
     && test ! -f "$TMPD/out15.json"'

check "an UNRESOLVED conflict (resolvedValue already null) may be dropped without refusal" \
  'python3 -c "
import json
d = json.load(open(\"$TMPD/existing_full.json\"))
d[\"conflicts\"][0][\"resolvedValue\"] = None
d[\"conflicts\"][0][\"resolvedSource\"] = None
d[\"conflicts\"][0][\"resolvedAt\"] = None
json.dump(d, open(\"$TMPD/existing_unresolved.json\", \"w\"))
d[\"conflicts\"] = []
print(json.dumps(d))
" | python3 "$SCRIPT" --output "$TMPD/out16.json" --existing "$TMPD/existing_unresolved.json" --plugin-root "$(pwd)"'

# --- --help renders the numbered-list docstring readably (not collapsed run-on prose) ---
check "--help preserves the docstring's numbered-list line breaks" \
  'python3 "$SCRIPT" --help | grep -qF "2. services going from non-empty to empty"'

echo
echo "write-context-helper: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
