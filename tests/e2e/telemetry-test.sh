#!/usr/bin/env bash
# tests/e2e/telemetry-test.sh
# Proves /otel-test's generated telemetry test (scripts/telemetry_test.py) on real apps, to the
# issue's bar (#286): the generated test PASSES on an instrumented service, and FAILS, naming what
# is missing, when the instrumentation is taken away.
#   - Node.js: tests/enrich/node-app + the golden tracing.js, enriched with three spans and two
#     business metrics. Broken three ways: one metric removed, all enrichment removed, and the
#     bootstrap flag dropped from the package.json start script.
#   - Python (ASGI): fixtures/python-greenfield + the golden tracing.py. Broken two ways: the app
#     no longer importing the bootstrap, and the enrichment removed. Also run under pytest.
#   - Python (WSGI): a Flask app, to prove the WSGI caller. Broken two ways: the line that
#     instruments the app removed, and the enrichment removed.
#   - Every test also requires the request's http.server.request.duration in seconds with its
#     status code, which the generated dashboards read. Broken by putting the old HTTP names on
#     the wire (FastAPI through the instrumentation package, Flask without the deployment's
#     OTEL_SEMCONV_STABILITY_OPT_IN): every span still arrives, and the test must fail anyway.
# The rendered files must equal the goldens in tests/snapshots/telemetry-test/. No Docker.
# Needs Node 18+, Python 3.9+ with venv, and network for npm and pip.
set -euo pipefail
cd "$(dirname "$0")/../.."
SRC=$PWD
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
enrich() { python3 "$SRC/scripts/enrich.py" "$@"; }
render() { python3 "$SRC/scripts/telemetry_test.py" render "$@"; }
CTX="$SRC/tests/enrich/context.json"
metric() { python3 "$SRC/scripts/enrich.py" metric --context "$CTX" "$@"; }
ln_of() { grep -n -F -- "$2" "$1" | head -1 | cut -d: -f1; }
failed=0
ok() { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; failed=1; }
# passes <name> <cmd...>: the test run exits 0.
passes() { local name="$1"; shift; if "$@" > "$WORK/run.log" 2>&1; then ok "$name"; else bad "$name"; tail -30 "$WORK/run.log"; fi; }
# fails_with <name> <words that must appear> <words that must NOT appear, or -> <cmd...>
fails_with() {
  local name="$1" want="$2" unwanted="$3"; shift 3
  if "$@" > "$WORK/run.log" 2>&1; then bad "$name (the test still passed)"; return; fi
  if ! grep -qF -- "$want" "$WORK/run.log"; then bad "$name (failed, but without: $want)"; tail -30 "$WORK/run.log"; return; fi
  if [ "$unwanted" != "-" ] && grep -qF -- "$unwanted" "$WORK/run.log"; then bad "$name (also blamed: $unwanted)"; tail -30 "$WORK/run.log"; return; fi
  ok "$name"
}

# ---------------------------------------------------------------- Node.js
mkdir -p "$WORK/node"
cp -R "$SRC/tests/enrich/node-app/." "$WORK/node/"
cp "$SRC/tests/snapshots/instrument/nodejs/tracing.js" "$WORK/node/tracing.js"
cd "$WORK/node"
npm install --no-audit --no-fund --loglevel=error
npm install --no-audit --no-fund --loglevel=error --save @opentelemetry/api
node_enrich() {
  enrich span --root . --file lib/orders.js --function checkout --span-name orders.checkout --tracer-name enrich-orders >/dev/null
  enrich span --root . --file lib/orders.js --function loadLines --span-name orders.loadLines --tracer-name enrich-orders >/dev/null
  enrich span --root . --file lib/pricing.js --function Pricing.total --span-name pricing.total --tracer-name enrich-orders >/dev/null
  local ret="return { cartId, lines, status: 'confirmed' };"
  metric --root . --file lib/orders.js --function checkout --at "$(ln_of lib/orders.js "$ret")" --where before \
    --name com.example.checkout.order_placed --meter-name enrich-orders >/dev/null
  metric --root . --file lib/orders.js --function checkout --at "$(ln_of lib/orders.js "$ret")" --where before \
    --name com.example.checkout.payment_duration --value "(Date.now() - startedAt) / 1000" --meter-name enrich-orders >/dev/null
}
node_enrich
render --root . --spec "$SRC/tests/telemetry-test/node.spec.json" >/dev/null
cmp -s otel.test.cjs "$SRC/tests/snapshots/telemetry-test/otel.test.cjs" \
  && ok "node: the rendered test equals the golden" || { bad "node: rendered test differs from the golden"; diff otel.test.cjs "$SRC/tests/snapshots/telemetry-test/otel.test.cjs" | head; }
NODE_TEST=(node --test otel.test.cjs)
passes "node: the generated test passes on the instrumented service" "${NODE_TEST[@]}"
enrich remove --root . --id metric-com-example-checkout-order-placed >/dev/null
fails_with "node: with one business metric removed it fails and names that metric only" \
  'metric "com.example.checkout.order_placed"' 'span "' "${NODE_TEST[@]}"
enrich remove --root . >/dev/null
fails_with "node: with the enrichment removed it fails and names the missing spans" 'span "orders.checkout"' "the request's own span" "${NODE_TEST[@]}"
grep -qF "Spans that did arrive:" "$WORK/run.log" && grep -qF "POST /checkout" "$WORK/run.log" \
  && ok "node: the failure lists what did arrive, so the cause is readable" || { bad "node: failure output lacks the arrived list"; tail -20 "$WORK/run.log"; }
node_enrich
passes "node: with the enrichment back it passes again" "${NODE_TEST[@]}"
# The service answers only when the fixed test environment reaches it (#319): the spec's `env`
# supplies AUTH_SECRET, and the same spec without it must fail on the status, not pass by luck.
cp index.js index.js.orig
sed -i.bak "s|^app.use(express.json());|app.use((req, res, next) => process.env.AUTH_SECRET === 'test-only-secret' ? next() : res.status(401).json({ error: 'no secret' }));\napp.use(express.json());|" index.js && rm index.js.bak
passes "node: the spec's env reaches the service, so a service that needs a secret answers" "${NODE_TEST[@]}"
python3 -c 'import json, sys; s = json.load(open(sys.argv[1])); del s["env"]; json.dump(s, open(sys.argv[2], "w"))' \
  "$SRC/tests/telemetry-test/node.spec.json" "$WORK/node-no-env.json"
render --root . --spec "$WORK/node-no-env.json" --force >/dev/null
fails_with "node: without the env the same service answers 401 and the test fails on the status" "401" - "${NODE_TEST[@]}"
mv index.js.orig index.js
render --root . --spec "$SRC/tests/telemetry-test/node.spec.json" --force >/dev/null
passes "node: restored, it passes again" "${NODE_TEST[@]}"
# A service whose entry exists only after a build, at a path nothing can write down (#319): the
# build writes dist/<nested>/server.js, the spec's startSearch finds it by name on every run.
cat > build.js <<'BUILDJS'
const fs = require('fs');
fs.mkdirSync('dist/mirror/of/checkout', { recursive: true });
fs.writeFileSync('dist/mirror/of/checkout/server.js', "require('../../../../index.js');\n");
BUILDJS
python3 - "$SRC/tests/telemetry-test/node.spec.json" "$WORK/node-build.json" <<'PYSPEC'
import json, sys
s = json.load(open(sys.argv[1]))
del s["startScript"]
s["start"] = ["-r", "./tracing.js"]
s["build"] = ["node", "build.js"]
s["startSearch"] = {"dir": "dist", "file": "server.js"}
json.dump(s, open(sys.argv[2], "w"))
PYSPEC
rm -rf dist
render --root . --spec "$WORK/node-build.json" --force >/dev/null
passes "node: the build runs, the entry is found under dist by name, and the test passes" "${NODE_TEST[@]}"
rm -rf dist
fails_with "node: with the build skipped and nothing built it says to build first" "Build the service first" - env OTEL_TEST_SKIP_BUILD=1 "${NODE_TEST[@]}"
mkdir -p dist/mirror/of/checkout dist/stale
printf "require('../../../../index.js');\n" > dist/mirror/of/checkout/server.js
printf "require('../../index.js');\n" > dist/stale/server.js
fails_with "node: two entries with the same name are refused, naming both" "more than one server.js under dist" - env OTEL_TEST_SKIP_BUILD=1 "${NODE_TEST[@]}"
rm -rf dist
sed 's|"build.js"|"nope.js"|' "$WORK/node-build.json" > "$WORK/node-build-bad.json"
render --root . --spec "$WORK/node-build-bad.json" --force >/dev/null
fails_with "node: a build that fails stops the test with its output" "the build command failed (node nope.js)" - "${NODE_TEST[@]}"
rm -rf dist build.js
render --root . --spec "$SRC/tests/telemetry-test/node.spec.json" --force >/dev/null
passes "node: restored, it passes again" "${NODE_TEST[@]}"
sed -i.bak 's|"start": "node -r ./tracing.js index.js"|"start": "node index.js"|' package.json && rm package.json.bak
fails_with "node: with the bootstrap flag dropped from the start script it fails and says so" \
  "no longer loads the OpenTelemetry bootstrap: node index.js" - "${NODE_TEST[@]}"
sed -i.bak 's|"start": "node index.js"|"start": "node -r ./tracing.js index.js \&\& echo done"|' package.json && rm package.json.bak
fails_with "node: a start script it cannot follow fails with a pointer to regenerate" "Re-run /otel-test --force" - "${NODE_TEST[@]}"

# ---------------------------------------------------------------- Python (ASGI, FastAPI)
mkdir -p "$WORK/py"
cp "$SRC/fixtures/python-greenfield/app.py" "$SRC/tests/snapshots/instrument/python/tracing.py" \
   "$SRC/tests/snapshots/instrument/python/requirements.txt" "$WORK/py/"
cd "$WORK/py"
printf 'import tracing\nfrom app import app\ntracing.instrument_fastapi(app)\n' > main.py
python3 -m venv "$WORK/venv"
SPEC=$(sed -nE 's/^opentelemetry-instrumentation-[a-z0-9-]+(.*)$/\1/p' requirements.txt | head -1)
"$WORK/venv/bin/pip" install -q --disable-pip-version-check -r requirements.txt pytest flask "opentelemetry-instrumentation-flask$SPEC"
py_enrich() {
  enrich span --root . --file app.py --function reserve_stock --span-name inventory.reserve_stock --tracer-name inventory-api >/dev/null
  local ret='return {"reserved": True'
  metric --root . --file app.py --function reserve_stock --at "$(ln_of app.py "$ret")" --where before \
    --name com.example.inventory.reservations --meter-name inventory-api >/dev/null
  metric --root . --file app.py --function reserve_stock --at "$(ln_of app.py "$ret")" --where before \
    --name com.example.inventory.reserved_quantity --value "update.quantity" --meter-name inventory-api >/dev/null
}
py_enrich
render --root . --spec "$SRC/tests/telemetry-test/python.spec.json" >/dev/null
cmp -s test_otel.py "$SRC/tests/snapshots/telemetry-test/test_otel.py" \
  && ok "python: the rendered test equals the golden" || { bad "python: rendered test differs from the golden"; diff test_otel.py "$SRC/tests/snapshots/telemetry-test/test_otel.py" | head; }
PY_TEST=("$WORK/venv/bin/python" -m unittest test_otel)
passes "python: the generated test passes on the instrumented service (unittest)" "${PY_TEST[@]}"
passes "python: pytest runs the same file" "$WORK/venv/bin/python" -m pytest -q test_otel.py
printf 'from app import app\n' > main.py
fails_with "python: when the app no longer imports the bootstrap it fails and says nothing would be exported" \
  "no longer imports the OpenTelemetry bootstrap (tracing)" - "${PY_TEST[@]}"
printf 'import tracing\nfrom app import app\ntracing.instrument_fastapi(app)\n' > main.py
enrich remove --root . >/dev/null
fails_with "python: with the enrichment removed it fails and names the span and both metrics" \
  'span "inventory.reserve_stock"' "the request's own span" "${PY_TEST[@]}"
grep -qF 'metric "com.example.inventory.reservations"' "$WORK/run.log" && grep -qF 'metric "com.example.inventory.reserved_quantity"' "$WORK/run.log" \
  && ok "python: both missing metrics are named" || { bad "python: a missing metric was not named"; tail -20 "$WORK/run.log"; }
py_enrich
cat > early.py <<'PY'
import unittest
from opentelemetry import trace
from opentelemetry.sdk.trace import TracerProvider
trace.set_tracer_provider(TracerProvider())   # something else set OpenTelemetry up first
import test_otel
if __name__ == "__main__":
    unittest.main(module=test_otel)
PY
fails_with "python: when OpenTelemetry was already set up in the process, it says to run on its own" \
  "Run this file in its own process" - "$WORK/venv/bin/python" early.py
# The request's duration metric under the name the dashboards query (#192): FastAPI 0.142.0+
# reports the stable names itself, so the test above passed on them. The instrumentation package,
# with no OTEL_SEMCONV_STABILITY_OPT_IN, reports the old ones: every span still arrives and every
# dashboard panel is empty, and the test must say exactly that.
fails_with "python: on the old HTTP names (package, no opt-in) it fails on the duration metric and names the fix" \
  "the old HTTP name http.server.duration was recorded instead" "the request's own span" \
  env OTEL_AS_CODE_FASTAPI_SOURCE=package "${PY_TEST[@]}"
grep -qF "OTEL_SEMCONV_STABILITY_OPT_IN=http/dup" "$WORK/run.log" && ! grep -qF 'span "inventory.reserve_stock"' "$WORK/run.log" \
  && ok "python: that failure names the setting and blames no span" || { bad "python: the old-name failure is not specific"; tail -20 "$WORK/run.log"; }
spec_with_optin() { python3 -c 'import json, sys; s = json.load(open(sys.argv[1])); s.setdefault("env", {})["OTEL_SEMCONV_STABILITY_OPT_IN"] = "http/dup"; json.dump(s, open(sys.argv[2], "w"))' "$@"; }
spec_with_optin "$SRC/tests/telemetry-test/python.spec.json" "$WORK/py-optin.json"
render --root . --spec "$WORK/py-optin.json" --force >/dev/null
passes "python: with the deployment's opt-in in the spec's env, the package's stable names pass" \
  env OTEL_AS_CODE_FASTAPI_SOURCE=package "${PY_TEST[@]}"
render --root . --spec "$SRC/tests/telemetry-test/python.spec.json" --force >/dev/null

# ---------------------------------------------------------------- Python (WSGI, Flask)
mkdir -p "$WORK/flask"
cp "$SRC/tests/telemetry-test/flask-app.py" "$WORK/flask/wsgi.py"
cd "$WORK/flask"
enrich span --root . --file wsgi.py --function find_item --span-name catalog.find_item --tracer-name catalog >/dev/null
render --root . --spec "$SRC/tests/telemetry-test/flask.spec.json" >/dev/null
FLASK_TEST=("$WORK/venv/bin/python" -m unittest test_otel)
passes "flask: the generated test passes through the WSGI caller, query string included" "${FLASK_TEST[@]}"
sed -i.bak '/FlaskInstrumentor().instrument_app(app)/d' wsgi.py && rm wsgi.py.bak
fails_with "flask: with the line that instruments the app removed it fails and names the request's span only" \
  "the request's own span \"GET /items/<int:item_id>\"" 'span "catalog.find_item"' "${FLASK_TEST[@]}"
cp "$SRC/tests/telemetry-test/flask-app.py" wsgi.py
fails_with "flask: with the enrichment removed it fails and names the span" 'span "catalog.find_item"' "the request's own span" "${FLASK_TEST[@]}"
enrich span --root . --file wsgi.py --function find_item --span-name catalog.find_item --tracer-name catalog >/dev/null
passes "flask: with the enrichment back it passes again" "${FLASK_TEST[@]}"
# Flask's instrumentation has no release that defaults to the stable HTTP names: the spec carries
# the deployment's OTEL_SEMCONV_STABILITY_OPT_IN. Without it the duration metric is the old one.
python3 -c 'import json, sys; s = json.load(open(sys.argv[1])); del s["env"]; json.dump(s, open(sys.argv[2], "w"))' \
  "$SRC/tests/telemetry-test/flask.spec.json" "$WORK/flask-no-optin.json"
render --root . --spec "$WORK/flask-no-optin.json" --force >/dev/null
fails_with "flask: without the stability opt-in it fails on the duration metric only, naming the old name" \
  "the old HTTP name http.server.duration was recorded instead" 'span "catalog.find_item"' "${FLASK_TEST[@]}"
grep -qF "the request's own span" "$WORK/run.log" \
  && { bad "flask: the old-name failure also blamed the request's span"; tail -20 "$WORK/run.log"; } \
  || ok "flask: the old-name failure blames only the metric"
render --root . --spec "$SRC/tests/telemetry-test/flask.spec.json" --force >/dev/null
passes "flask: restored, it passes again" "${FLASK_TEST[@]}"

[ "$failed" -eq 0 ] && echo "TELEMETRY TEST E2E PASS: the generated tests pass when instrumented and fail, naming the gap, when not"
exit "$failed"
