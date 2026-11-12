#!/usr/bin/env bash
# Seeds the current directory with the routing-eval fixture: fixtures/nodejs-greenfield plus
# evals/routing/fixture-overlay/, committed as a clean git repo. Used by every case's
# scaffold.sh (claude plugin eval, condition a) and by run-headless.sh (condition b).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
cp -R "$ROOT/fixtures/nodejs-greenfield/." .
cp -R "$HERE/fixture-overlay/." .
python3 - <<'PY'
import json
p = json.load(open("package.json"))
p["scripts"]["test"] = "node --test test/"
p.pop("devDependencies", None)
json.dump(p, open("package.json", "w"), indent=2)
open("package.json", "a").write("\n")
PY
printf 'node_modules/\n' > .gitignore
git init -q -b main
git add -A
git -c user.name=eval -c user.email=eval@example.invalid commit -qm "checkout-api"
