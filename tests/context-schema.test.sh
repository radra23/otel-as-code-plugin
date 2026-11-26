#!/usr/bin/env bash
# tests/context-schema.test.sh
# #257: scripts/context-schema.json is the machine-readable form of the cache ownership contract.
#   - The scanner reads it (contextSchemaPath, passed by every command that dispatches it), and
#     the "Cache ownership contract" prose in agents/repo-context-scanner.md keeps only the
#     reasoning and exceptions; every field that prose names under an owner has that owner here.
#   - scripts/write_context.py reads the user-owned fields from it, not from a list of its own:
#     a field added to the schema is enforced without touching the script.
#   - The slim directory build ships it, since write_context.py fails without it.
set -uo pipefail
cd "$(dirname "$0")/.."
pass=0; fail=0
check() { if eval "$2"; then echo "PASS: $1"; pass=$((pass+1)); else echo "FAIL: $1"; fail=$((fail+1)); fi; }
SCHEMA=scripts/context-schema.json
SCANNER=agents/repo-context-scanner.md

# parity <schema>: every field the scanner prose names under an owner is in that owner's list in
# the schema (the lists themselves live only in the schema now); prints the differences.
parity() {
  python3 - "$1" "$SCANNER" <<'PY'
import json, re, sys
schema = json.load(open(sys.argv[1]))
text = open(sys.argv[2], encoding="utf-8").read()
section = text.split("## Cache ownership contract", 1)[1].split("\nMatch services between", 1)[0]
blocks = {"scanner": section.split("**Scanner-owned", 1)[1].split("**User-owned", 1)[0],
          "user": section.split("**User-owned", 1)[1]}

def owned(owner):
    out = set(schema["topLevel"][owner])
    out |= {"services[]." + f for f in schema["services"][owner]}
    out |= {"conflicts[]." + f for f in schema["conflicts"][owner]}
    if owner == "user":
        out |= {"services[]." + f for f in schema["services"]["userWhenConfirmed"]}
    return out

every = owned("scanner") | owned("user")
problems = []
for owner, block in blocks.items():
    names = set(re.findall(r"`((?:services\[\]\.|conflicts\[\]\.)?[A-Za-z_]+(?:\.\*)?)`", block))
    for n in sorted(names & every):          # names that are fields; other backticked words are not
        if n not in owned(owner):
            problems.append(f"the prose puts {n} under {owner}-owned; the schema does not")
    for n in sorted(n for n in names if n.startswith(("services[].", "conflicts[].")) and n not in every):
        problems.append(f"the prose names {n} under {owner}-owned; the schema has no such field")
ua = schema["services"]["userAdded"]
if f'`{ua["field"]}: "{ua["value"]}"`' not in blocks["user"]:
    problems.append("the prose's user-added marker is not the schema's")
if f'`{schema["services"]["confirmedValue"]}`' not in blocks["user"]:
    problems.append("the prose does not name the schema's confirmed value")
for key in ("topLevel", "services", "conflicts", "contextSchemaPath"):
    if f"`{key}`" not in section:
        problems.append(f"the contract does not point at the schema's `{key}`")
print("\n".join(problems))
PY
}

check "the schema is valid JSON with every owner list non-empty" \
  'python3 -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if all(d[k][o] for k in (\"topLevel\",\"services\",\"conflicts\") for o in (\"scanner\",\"user\")) else 1)" $SCHEMA'
diff=$(parity "$SCHEMA")
check "every field the scanner contract names under an owner has that owner in the schema" '[ -z "$diff" ]'
[ -n "$diff" ] && echo "$diff" | sed 's/^/    /'

# Teeth: a schema that gives a field the prose names the other owner must be caught.
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["services"]["user"].remove("scopeOverride"); d["services"]["scanner"].append("scopeOverride"); json.dump(d,open(sys.argv[2],"w"))' $SCHEMA "$T/moved.json"
check "parity catches a field the prose names moved to the wrong owner (teeth)" '[ -n "$(parity "$T/moved.json")" ]'
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["services"]["scanner"].remove("existingOtel.*"); json.dump(d,open(sys.argv[2],"w"))' $SCHEMA "$T/dropped.json"
check "parity catches a field the prose names that the schema dropped (teeth)" '[ -n "$(parity "$T/dropped.json")" ]'

# The scanner reads the file, and every command that dispatches it passes the path.
check "the scanner declares contextSchemaPath, and what it does when the file cannot be read" \
  'grep -qF -- "- \`contextSchemaPath\` — the absolute path to \`scripts/context-schema.json\`" $SCANNER && grep -qF "Never drop a field because you could not tell who owns it." $SCANNER'
check "the contract no longer restates the owner lists (no field-list bullets under Scanner-owned)" \
  '! awk "/^\*\*Scanner-owned/{on=1;next} /^\*\*User-owned/{on=0} on" $SCANNER | grep -q "^- "'
for c in $(grep -l "otel-as-code:repo-context-scanner" commands/*.md); do
  check "$c passes contextSchemaPath to the scanner" 'grep -qF "contextSchemaPath" $c'
done
check "every dispatching command points at the same file" \
  '[ "$(grep -ho "\${CLAUDE_PLUGIN_ROOT}/scripts/context-schema.json" $(grep -l "otel-as-code:repo-context-scanner" commands/*.md) | sort -u | wc -l | tr -d " ")" = 1 ]'

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
# Types: every owned field has one, every typed field has an owner, and the scanner's own Output
# template agrees with them (a field the template shows as a number is typed "number" here).
types_problems() {
  python3 - "$1" "$SCANNER" <<'PY'
import json, re, sys
schema = json.load(open(sys.argv[1]))
text = open(sys.argv[2], encoding="utf-8").read()
kinds = {"string": str, "number": (int, float), "boolean": bool, "array": list, "object": dict}
problems = []
for sec in ("topLevel", "services", "conflicts"):
    s = schema[sec]
    owned = {f.removesuffix(".*") for f in s["scanner"] + s["user"]} | set(s.get("matchBy", []))
    for field, rule in s.get("userWhenConfirmed", {}).items():
        owned |= {field, *rule["with"]}
    if sec == "topLevel":
        owned |= {"schemaVersion", "services", "conflicts"}
    typed = set(s["types"])
    problems += [f"{sec}.{f} has an owner but no type" for f in sorted(owned - typed)]
    problems += [f"{sec}.{f} has a type but no owner" for f in sorted(typed - owned)]
    problems += [f"{sec}.{f}: unknown type {t!r}" for f, t in s["types"].items() if t not in kinds]
template = json.loads(re.search(r"## Output.*?```json\n(.*?)\n```", text, re.S).group(1))
def agree(obj, sec, where):
    for f, t in schema[sec]["types"].items():
        v = obj.get(f)
        if v is None or t not in kinds:
            continue
        if not isinstance(v, kinds[t]) or (t == "number" and isinstance(v, bool)):
            problems.append(f"the scanner template's {where}{f} is {v!r}; the schema types it {t}")
agree(template, "topLevel", "")
for key in ("services", "conflicts"):
    for e in template[key]:
        agree(e, key, f"{key}[].")
print("\n".join(problems))
PY
}
tp=$(types_problems "$SCHEMA")
check "every owned field has a type, every typed field an owner, and the scanner template agrees" '[ -z "$tp" ]'
[ -n "$tp" ] && echo "$tp" | sed 's/^/    /'
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["services"]["types"]["inScope"]="string"; json.dump(d,open(sys.argv[2],"w"))' $SCHEMA "$T/badtype.json"
check "a type that disagrees with the scanner template is caught (teeth)" '[ -n "$(types_problems "$T/badtype.json")" ]'
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); del d["services"]["types"]["hostConfidence"]; json.dump(d,open(sys.argv[2],"w"))' $SCHEMA "$T/untyped.json"
check "an owned field with no type is caught (teeth)" '[ -n "$(types_problems "$T/untyped.json")" ]'

# write_context.py refuses a wrong type, and accepts null and an untyped field.
typed_write() {  # <python expression mutating d> -> rc of the write
  python3 -c 'import json,sys
d={"schemaVersion":"2","scannedAt":sys.argv[1],"services":[{"id":"a","nameConfidence":0.9,"inScope":True}],
   "conflicts":[{"serviceId":"a","attribute":"service.name","sources":[]}]}
exec(sys.argv[2]); print(json.dumps(d))' "$NOW" "$1" | python3 scripts/write_context.py --output "$T/typed.json" 2>"$T/typed.err"
}
check "a well-typed document is written" 'typed_write "pass"'
for m in 'd["services"][0]["nameConfidence"]="0.9"' 'd["services"][0]["inScope"]="false"' \
         'd["services"][0]["nameConfidence"]=True' 'd["conflicts"][0]["conflict_resolved"]="yes"' \
         'd["businessAttrs"]={}' 'd["schemaVersion"]=2'; do
  check "write_context.py refuses a wrong type: $m" '! typed_write "$m" && grep -q "not a JSON" "$T/typed.err"'
done
check "null is accepted for a typed field" 'typed_write "d[\"services\"][0][\"languageVersion\"]=None"'
check "a field the schema does not type is not checked" 'typed_write "d[\"services\"][0][\"somethingNew\"]=42"'

check "the slim directory build ships the schema" 'grep -qF "scripts/context-schema.json" scripts/build-directory.sh'

echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
