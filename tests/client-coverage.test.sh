#!/usr/bin/env bash
# tests/client-coverage.test.sh: checks scripts/client-coverage.json against the PUBLISHED packages,
# so the table /otel-enrich --clients reads cannot drift into claims nobody checked.
#   - Node.js: every "bundle" package is a dependency of the bundle version the golden package.json
#     pins; every "manual" package exists on npm.
#   - Python: each package is downloaded (the wheel only, at the release the golden requirements
#     pin), and the wheel must hold the module and the instrumentor class the table names, and
#     declare the client distributions the table lists for it.
# Needs network (npm, PyPI), so it runs in the enrich-clients CI job, not with the offline tests.
set -uo pipefail
cd "$(dirname "$0")/.."
TMPD=$(mktemp -d); trap 'rm -rf "$TMPD"' EXIT
pass=0; fail=0
ok() { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

BUNDLE=$(python3 -c 'import json; print(json.load(open("scripts/client-coverage.json"))["nodejs"]["bundlePackage"])')
PIN=$(python3 -c 'import json, sys; print(json.load(open("tests/snapshots/instrument/nodejs/package.json"))["dependencies"][sys.argv[1]].lstrip("^~"))' "$BUNDLE")
npm view "$BUNDLE@$PIN" dependencies --json > "$TMPD/bundle.json" 2>"$TMPD/npm.err" \
  || { echo "FAIL: npm view $BUNDLE@$PIN failed"; cat "$TMPD/npm.err"; exit 1; }
missing=$(python3 - "$TMPD/bundle.json" <<'PY'
import json, sys
deps = json.load(open(sys.argv[1]))
table = json.load(open("scripts/client-coverage.json"))["nodejs"]["bundle"]
print(" ".join(f"{c}->{p}" for c, p in table.items() if p not in deps))
PY
)
[ -z "$missing" ] && ok "node: every bundle row is a dependency of $BUNDLE@$PIN" || bad "node: not in $BUNDLE@$PIN: $missing"
for pkg in $(python3 -c 'import json; print(" ".join(json.load(open("scripts/client-coverage.json"))["nodejs"]["manual"].values()))'); do
  [ "$(npm view "$pkg" name 2>/dev/null)" = "$pkg" ] && ok "node: $pkg exists on npm" || bad "node: $pkg not found on npm"
done

SPEC=$(sed -nE 's/^opentelemetry-instrumentation-[a-z0-9-]+(.*)$/\1/p' tests/snapshots/instrument/python/requirements.txt | head -1)
[ -n "$SPEC" ] || { echo "FAIL: no opentelemetry-instrumentation pin in the golden requirements.txt"; exit 1; }
while IFS=$'\t' read -r label package module class clients; do
  if ! python3 -m pip download -q --disable-pip-version-check --no-deps -d "$TMPD/w" "$package$SPEC" >"$TMPD/pip.log" 2>&1; then
    bad "python: $package$SPEC could not be downloaded"; tail -2 "$TMPD/pip.log"; continue
  fi
  if python3 - "$TMPD/w" "$package" "$module" "$class" "$clients" <<'PY'
import glob, re, sys, zipfile
wdir, package, module, cls, clients = sys.argv[1:6]
norm = lambda s: re.sub(r"[-_.]+", "-", s).lower()
wheels = glob.glob(f"{wdir}/{package.replace('-', '_')}-*.whl")
if len(wheels) != 1:
    sys.exit(f"  expected one wheel for {package}, found {wheels}")
z = zipfile.ZipFile(wheels[0])
base = module.replace(".", "/") + "/"
files = {n: z.read(n).decode("utf-8", "replace") for n in z.namelist() if n.startswith(base) and n.endswith(".py")}
if base + "__init__.py" not in files:
    sys.exit(f"  no module {module} in {wheels[0]}")
init = files[base + "__init__.py"]
defined = any(re.search(rf"^class {cls}\b", t, re.M) for t in files.values())
exported = re.search(rf"^class {cls}\b", init, re.M) or re.search(rf"\bimport\b[^\n]*\b{cls}\b|^\s+{cls},?$", init, re.M)
if not (defined and exported):
    sys.exit(f"  {module} does not define and export {cls}")
declared = {norm(m) for m in re.findall(r"""["']\s*([A-Za-z0-9][A-Za-z0-9._-]*)""", files.get(base + "package.py", ""))}
want = {norm(c) for c in clients.split(",") if c}
if not want <= declared:
    sys.exit(f"  {package} declares {sorted(declared)}, the table lists {sorted(want)}")
PY
  then ok "python: $package has $module.$class and instruments ${clients:-the standard library}"
  else bad "python: $label does not match the published $package"
  fi
done < <(python3 -c '
import json
for r in json.load(open("scripts/client-coverage.json"))["python"]["packages"]:
    print("\t".join([r["label"], r["package"], r["module"], r["class"], ",".join(r["clients"])]))')

echo
echo "client-coverage: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
