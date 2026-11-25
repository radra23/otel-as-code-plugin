#!/usr/bin/env bash
# tests/context-schema.test.sh
# #257: scripts/context-schema.json is the machine-readable form of the cache ownership contract.
#   - It names the same scanner-owned and user-owned fields as the "Cache ownership contract" in
#     agents/repo-context-scanner.md, read out of that prose, so the two cannot drift.
#   - scripts/write_context.py reads the user-owned fields from it, not from a list of its own:
#     a field added to the schema is enforced without touching the script.
#   - The slim directory build ships it, since write_context.py fails without it.
set -uo pipefail
cd "$(dirname "$0")/.."
pass=0; fail=0
check() { if eval "$2"; then echo "PASS: $1"; pass=$((pass+1)); else echo "FAIL: $1"; fail=$((fail+1)); fi; }
SCHEMA=scripts/context-schema.json
SCANNER=agents/repo-context-scanner.md

# parity <schema>: compares the schema's fields with the scanner prose; prints the differences.
parity() {
  python3 - "$1" "$SCANNER" <<'PY'
import json, re, sys
schema = json.load(open(sys.argv[1]))
text = open(sys.argv[2], encoding="utf-8").read()
section = text.split("## Cache ownership contract", 1)[1].split("\nMatch services between", 1)[0]
scanner_block = section.split("**Scanner-owned", 1)[1].split("**User-owned", 1)[0]
user_block = section.split("**User-owned", 1)[1]

def prose_fields(block):
    """The fields each bullet is about: the backticked names before its first explanation
    (' (', ' when ', ' — '), qualified by the scope (services[]., conflicts[].) of the first."""
    out = set()
    for bullet in re.split(r"\n- ", "\n" + block)[1:]:
        # A bullet runs on over its indented lines; the paragraph after a blank line is not part of it.
        lines = bullet.split("\n")
        head = lines[0]
        for more in lines[1:]:
            if not more.startswith("  "):
                break
            head += " " + more.strip()
        for cut in (" (", " when ", " — "):
            head = head.split(cut)[0]
        names = re.findall(r"`([^`]+)`", head)
        if not names:
            continue
        scope = next((p for p in ("services[].", "conflicts[].") if names[0].startswith(p)), "")
        for n in names:
            out.add(n if n.startswith(("services[].", "conflicts[].")) else scope + n)
    return out

def schema_fields(owner):
    out = {f for f in schema["topLevel"][owner]}
    out |= {"services[]." + f for f in schema["services"][owner]}
    out |= {"conflicts[]." + f for f in schema["conflicts"][owner]}
    if owner == "user":
        for field, rule in schema["services"]["userWhenConfirmed"].items():
            out |= {"services[]." + f for f in [field] + rule["with"]}
    return out

problems = []
for owner, block in (("scanner", scanner_block), ("user", user_block)):
    prose, sch = prose_fields(block), schema_fields(owner)
    if prose - sch: problems.append(f"{owner}-owned in the prose, not in the schema: {sorted(prose - sch)}")
    if sch - prose: problems.append(f"{owner}-owned in the schema, not in the prose: {sorted(sch - prose)}")
ua = schema["services"]["userAdded"]
if f'`{ua["field"]}: "{ua["value"]}"`' not in user_block:
    problems.append("the prose's user-added marker is not the schema's")
for field, rule in schema["services"]["userWhenConfirmed"].items():
    if f'`{rule["sourceField"]}` is `{schema["services"]["confirmedValue"]}`' not in user_block:
        problems.append(f"the prose does not make services[].{field} user-owned on {rule['sourceField']}")
print("\n".join(problems))
PY
}

check "the schema is valid JSON with every owner list non-empty" \
  'python3 -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if all(d[k][o] for k in (\"topLevel\",\"services\",\"conflicts\") for o in (\"scanner\",\"user\")) else 1)" $SCHEMA'
diff=$(parity "$SCHEMA")
check "the schema and the scanner's ownership contract name the same fields, owner for owner" '[ -z "$diff" ]'
[ -n "$diff" ] && echo "$diff" | sed 's/^/    /'

# Teeth: a schema that moves one field to the wrong owner, or drops one, must be caught.
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["topLevel"]["user"].remove("namespace"); d["topLevel"]["scanner"].append("namespace"); json.dump(d,open(sys.argv[2],"w"))' $SCHEMA "$T/moved.json"
check "parity catches a field moved to the wrong owner (teeth)" '[ -n "$(parity "$T/moved.json")" ]'
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["conflicts"]["user"].remove("resolvedAt"); json.dump(d,open(sys.argv[2],"w"))' $SCHEMA "$T/dropped.json"
check "parity catches a dropped field (teeth)" '[ -n "$(parity "$T/dropped.json")" ]'

check "write_context.py has no hand-kept user-owned list any more" \
  '! grep -qE "TOP_LEVEL_USER_OWNED = \[|for field in \(\"namespace\", \"team\"\)" scripts/write_context.py'
# Behaviour: a copy of the script next to a schema with one more user-owned field refuses to empty
# that field, which only happens if the script reads the file.
mkdir -p "$T/s"
cp scripts/write_context.py "$T/s/"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["topLevel"]["user"].append("pocField"); json.dump(d,open(sys.argv[2],"w"))' $SCHEMA "$T/s/context-schema.json"
NOW=$(python3 -c 'from datetime import datetime,timezone; print(datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))')
printf '{"schemaVersion":"1.0","scannedAt":"%s","services":[{"id":"a"}],"pocField":"kept"}' "$NOW" > "$T/old.json"
out=$(printf '{"schemaVersion":"1.0","scannedAt":"%s","services":[{"id":"a"}],"pocField":null}' "$NOW" \
  | python3 "$T/s/write_context.py" --output "$T/out.json" --existing "$T/old.json" 2>&1); rc=$?
check "write_context.py enforces a user-owned field it learns from the schema" \
  '[ "$rc" = 1 ] && grep -q "pocField" <<<"$out" && [ ! -e "$T/out.json" ]'
rm "$T/s/context-schema.json"
out=$(printf '{"scannedAt":"%s","services":[]}' "$NOW" | python3 "$T/s/write_context.py" --output "$T/out.json" 2>&1); rc=$?
check "without the schema it refuses to write rather than guess" \
  '[ "$rc" = 1 ] && grep -q "cannot read the ownership schema" <<<"$out" && [ ! -e "$T/out.json" ]'
check "the slim directory build ships the schema" 'grep -qF "scripts/context-schema.json" scripts/build-directory.sh'

echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
