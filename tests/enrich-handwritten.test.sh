#!/usr/bin/env bash
# tests/enrich-handwritten.test.sh: `enrich.py handwritten` (#320), the report of telemetry the
# service's own code sets up by hand, which /otel-test cannot assert. Real files in a temp copy of
# tests/enrich/node-app: a real enrichment block made by `enrich.py span`, the golden bootstrap and
# telemetry test (generated, so skipped), hand-written calls in JavaScript, TypeScript and Python,
# a commented-out call, and a dependency under node_modules (skipped). No network.
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
pass=0; fail=0
check() { if eval "$2"; then echo "PASS: $1"; pass=$((pass+1)); else echo "FAIL: $1"; fail=$((fail+1)); fi; }
enrich() { python3 "$ROOT/scripts/enrich.py" "$@"; }
TMPD=$(mktemp -d); trap 'rm -rf "$TMPD"' EXIT
A="$TMPD/app"
mkdir -p "$A"; cp -R tests/enrich/node-app/. "$A/"

# A real enrichment block: its own getTracer must not be reported.
enrich span --root "$A" --file lib/orders.js --function checkout --span-name orders.checkout --tracer-name enrich-orders > /dev/null
# The plugin's own generated files: skipped by their header.
cp tests/snapshots/instrument/nodejs/tracing.js "$A/tracing.js"
cp tests/snapshots/telemetry-test/otel.test.cjs "$A/otel.test.cjs"
cp tests/snapshots/instrument/python/tracing.py "$A/tracing.py"
cat > "$A/lib/metrics.js" <<'JS'
const { metrics, trace } = require('@opentelemetry/api');
const meter = metrics.getMeter('billing');
// const old = metrics.getMeter('retired');
const tracer = trace.getTracer(
  'billing-tracer');
module.exports = { invoices: meter.createCounter('billing.invoices') };
JS
mkdir -p "$A/src"
printf "import { metrics } from '@opentelemetry/api';\nexport const m = metrics.getMeter(\`ts-meter\`);\n" > "$A/src/m.ts"
printf 'from opentelemetry import metrics, trace\n\nmeter = metrics.get_meter(__name__)\n# tracer = trace.get_tracer("retired")\ntracer = trace.get_tracer("jobs")\n' > "$A/jobs.py"
mkdir -p "$A/node_modules/somelib"
printf "require('@opentelemetry/api').trace.getTracer('somelib');\n" > "$A/node_modules/somelib/index.js"

hashes() { (cd "$A" && find . -type f -exec shasum {} + | sort); }
before=$(hashes)
out=$(enrich handwritten --root "$A"); rc=$?
check "exit 0 and writes nothing" '[ "$rc" -eq 0 ] && [ "$(hashes)" = "$before" ]'
expected="jobs.py:3  meter
jobs.py:5  tracer jobs
lib/metrics.js:2  meter billing
lib/metrics.js:4  tracer
src/m.ts:2  meter ts-meter"
check "reports exactly the hand-written calls, in order, with a plain-string name when there is one" \
  '[ "$out" = "$expected" ] || { echo "$out"; false; }'
check "the enrichment block's own getTracer is not reported" '! grep -q "orders.js" <<<"$out"'
check "the generated bootstrap and telemetry test are not reported" '! grep -qE "tracing\.(js|py)|otel\.test\.cjs" <<<"$out"'
check "commented-out calls and dependencies are not reported" '! grep -qE "retired|somelib|node_modules" <<<"$out"'
json=$(enrich handwritten --root "$A" --json)
check "--json carries file, line, kind and name (null when not a plain string)" \
  'python3 -c "import json,sys; d=json.loads(sys.argv[1]); assert d[0]==dict(file=\"jobs.py\",line=3,kind=\"meter\",name=None), d[0]; assert len(d)==5" "$json"'
check "--service-root narrows the scan" '[ "$(enrich handwritten --root "$A" --service-root src)" = "src/m.ts:2  meter ts-meter" ]'
check "a service with none says so" \
  'mkdir -p "$TMPD/empty" && [ "$(enrich handwritten --root "$TMPD/empty")" = "no hand-written meter or tracer found" ]'
msg=$(enrich handwritten --root "$A" --service-root ../.. 2>&1); rc=$?
check "a --service-root outside the project is refused" '[ "$rc" -eq 2 ] && grep -q "^REFUSED: " <<<"$msg"'

echo ""
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
