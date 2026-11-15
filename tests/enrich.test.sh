#!/usr/bin/env bash
# tests/enrich.test.sh: offline tests of scripts/enrich.py, which makes /otel-enrich's edits to
# hand-written code. Real files in a temp project. The enriched code is then RUN against a stub
# OpenTelemetry API that records what it does, so "the function still behaves the same" is
# observed, not assumed. No network, no SDK. Needs node (for `node --check` and the Node runs).
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
pass=0; fail=0
check() { if eval "$2"; then echo "PASS: $1"; pass=$((pass+1)); else echo "FAIL: $1"; fail=$((fail+1)); fi; }
enrich() { python3 "$ROOT/scripts/enrich.py" "$@"; }
TMPD=$(mktemp -d); trap 'rm -rf "$TMPD"' EXIT
N="$TMPD/node"; P="$TMPD/py"
fresh() { rm -rf "$N"; mkdir -p "$N"; cp -R tests/enrich/node-app/. "$N/"; }
snap() { (cd "$1" && find . -type f -not -path "./node_modules/*" -exec shasum {} + | sort) > "$TMPD/snap"; }
same() { (cd "$1" && find . -type f -not -path "./node_modules/*" -exec shasum {} + | sort) | cmp -s - "$TMPD/snap"; }
# refused <name> <dir> <expected words> <enrich args...>: exit 2, one REFUSED line with those
# words, and nothing written.
refused() {
  local name="$1" dir="$2" words="$3" msg rc; shift 3
  snap "$dir"
  msg=$(enrich "$@" 2>&1); rc=$?
  check "$name" '[ "$rc" -eq 2 ] && echo "$msg" | grep -q "^REFUSED: " && echo "$msg" | grep -qi -- "$words" && same "$dir"'
}
# insert_only <original> <edited>: the edit only ADDED lines (the original is what is left when
# the added lines go).
insert_only() {
  python3 - "$1" "$2" <<'PY'
import difflib, sys
a = open(sys.argv[1], newline="").read().splitlines(keepends=True)
b = open(sys.argv[2], newline="").read().splitlines(keepends=True)
ops = [t for t in difflib.SequenceMatcher(None, a, b, autojunk=False).get_opcodes() if t[0] != "equal"]
sys.exit(0 if ops and all(t[0] == "insert" for t in ops) else 1)
PY
}
SPAN=(--span-name orders.checkout --tracer-name enrich-orders)

# ================================================================== Node.js
fresh; snap "$N"
out=$(enrich span --root "$N" --file lib/orders.js --function checkout "${SPAN[@]}" --dry-run); rc=$?
check "node: --dry-run prints the diff, exits 1, writes nothing" \
  '[ "$rc" -eq 1 ] && echo "$out" | grep -q "^+.*startActiveSpan(.orders.checkout." && same "$N"'
check "node: the dry run names the missing direct dependency" \
  'echo "$out" | grep -q "^dependency: add \"@opentelemetry/api\" to dependencies in package.json"'
out=$(enrich span --root "$N" --file lib/orders.js --function checkout "${SPAN[@]}"); rc=$?
check "node: span applies (exit 0) and prints the same diff" '[ "$rc" -eq 0 ] && echo "$out" | grep -q "^OK: added span"'
check "node: the edit is insert-only (no original line changed or moved)" \
  'insert_only tests/enrich/node-app/lib/orders.js "$N/lib/orders.js"'
check "node: both blocks and the tracer block carry begin and end markers" \
  '[ "$(grep -c "otel-as-code: enrich begin orders-checkout" "$N/lib/orders.js")" = 2 ] && [ "$(grep -c "otel-as-code: enrich end orders-checkout" "$N/lib/orders.js")" = 2 ] && [ "$(grep -c "enrich begin otel-tracer" "$N/lib/orders.js")" = 1 ]'
check "node: the tracer goes after the 'use strict' directive, not before it" \
  '[ "$(head -1 "$N/lib/orders.js")" = "'"'"'use strict'"'"';" ] && sed -n 2p "$N/lib/orders.js" | grep -q "enrich begin otel-tracer"'
check "node: a CommonJS file gets require(), not import" 'grep -q "require(.@opentelemetry/api.)" "$N/lib/orders.js"'
enrich span --root "$N" --file lib/orders.js --function loadLines --span-name orders.loadLines --tracer-name enrich-orders >/dev/null
check "node: a second enrichment in the file reuses the tracer block" '[ "$(grep -c "enrich begin otel-tracer" "$N/lib/orders.js")" = 1 ]'
out=$(enrich span --root "$N" --file lib/orders.js --function describe --span-name orders.describe --tracer-name enrich-orders)
check "node: a non-async function gets a sync wrapper and the promise note" \
  'echo "$out" | grep -q "^note: .describe. is not async" && grep -q "startActiveSpan(.orders.describe., (otelSpan) =>" "$N/lib/orders.js"'
out=$(enrich span --root "$N" --file lib/pricing.js --function Pricing.total --span-name pricing.total --tracer-name enrich-orders)
check "node: Class.method picks the method, not the function of the same name" \
  'sed -n "/^  total(lines) {/,/^  }/p" "$N/lib/pricing.js" | grep -q "pricing.total" && ! sed -n "/^function total/,/^}/p" "$N/lib/pricing.js" | grep -q "otel"'
check "node: list shows every enrichment with its file and line" \
  '[ "$(enrich list --root "$N" | grep -c "orders-checkout\|orders-loadlines\|orders-describe\|pricing-total")" = 4 ]'

# The enriched code, run against a stub API.
mkdir -p "$N/node_modules/@opentelemetry/api"
cat > "$N/node_modules/@opentelemetry/api/index.js" <<'JS'
const spans = [];
const stack = [];
module.exports = {
  SpanStatusCode: { ERROR: 2 },
  trace: { getTracer: (scope) => ({ startActiveSpan: (name, fn) => {
    const s = { scope, name, parent: stack.length ? stack[stack.length - 1].name : null, status: null,
      ended: false, errors: 0, setStatus(x) { this.status = x.code; }, recordException() { this.errors++; },
      end() { this.ended = true; } };
    spans.push(s); stack.push(s);
    let r;
    try { r = fn(s); } finally { stack.pop(); }
    return r; } }) },
  _spans: spans,
};
JS
run=$(cd "$N" && node -e "
const orders = require('./lib/orders'); const { Pricing } = require('./lib/pricing'); const api = require('@opentelemetry/api');
(async () => {
  const ok = await orders.checkout('c1', false);
  let msg = null; try { await orders.checkout('c2', true); } catch (e) { msg = e.message; }
  const label = orders.describe(ok); const total = new Pricing(10).total(ok.lines);
  const s = api._spans;
  console.log(JSON.stringify({ status: ok.status, lines: ok.lines.length, msg, label, total,
    names: s.map((x) => x.name), ended: s.every((x) => x.ended), scope: [...new Set(s.map((x) => x.scope))],
    errors: s.filter((x) => x.status === 2 && x.errors === 1).map((x) => x.name) }));
})();" 2>&1)
check "node: enriched functions return what they returned before" \
  'echo "$run" | grep -q "\"status\":\"confirmed\",\"lines\":2" && echo "$run" | grep -q "\"label\":\"c1: sku-1x1, sku-2x2\",\"total\":900"'
check "node: a thrown error reaches the caller unchanged and is recorded on its span" \
  'echo "$run" | grep -q "\"msg\":\"cart c2 could not be charged\"" && echo "$run" | grep -q "\"errors\":\[\"orders.checkout\"\]"'
check "node: every span ends (async, sync, method, and the failing one), under the tracer name" \
  'echo "$run" | grep -q "\"ended\":true,\"scope\":\[\"enrich-orders\"\]" && echo "$run" | grep -q "\"names\":\[\"orders.checkout\",\"orders.loadLines\",\"orders.checkout\",\"orders.loadLines\",\"orders.describe\",\"pricing.total\"\]"'
rm -rf "$N/node_modules"

# semconv-lint, strict: the enriched files must not trip a severe rule.
lint_ok() {
  python3 -c "import json,sys; print(json.dumps({'tool_name':'Write','tool_input':{'file_path':sys.argv[1],'content':open(sys.argv[1]).read()}}))" "$1" \
    | OTEL_STRICT=1 bash hooks/semconv-lint.sh >/dev/null 2>&1
}
check "node: the enriched files pass semconv-lint in strict mode" 'lint_ok "$N/lib/orders.js" && lint_ok "$N/lib/pricing.js"'

# --- removal ---
snap "$N"
out=$(enrich remove --root "$N" --dry-run); rc=$?
check "node: remove --dry-run lists what would go, exits 1, writes nothing" \
  '[ "$rc" -eq 1 ] && echo "$out" | grep -q "would remove: .*orders-checkout.* from lib/orders.js" && same "$N"'
enrich remove --root "$N" --id orders-describe >/dev/null
check "node: remove --id takes one enrichment and leaves the others and the tracer" \
  '! grep -q "orders-describe" "$N/lib/orders.js" && grep -q "orders-checkout" "$N/lib/orders.js" && grep -q "enrich begin otel-tracer" "$N/lib/orders.js"'
refused "node: remove --id with an unknown id is refused" "$N" "no enrichment with id nope" remove --root "$N" --id nope
printf '\n// a later edit by the user\n' >> "$N/lib/orders.js"
check "node: remove takes everything that is left" 'enrich remove --root "$N" | grep -q "^OK: removed 3 enrichment(s) from 2 file(s)"'
check "node: the user's own later edit survives, and the rest is byte for byte the original" \
  'tail -1 "$N/lib/orders.js" | grep -q "a later edit by the user" && head -n "$(wc -l < tests/enrich/node-app/lib/orders.js)" "$N/lib/orders.js" | cmp -s - tests/enrich/node-app/lib/orders.js && cmp -s "$N/lib/pricing.js" tests/enrich/node-app/lib/pricing.js'
check "node: remove with nothing left is a no-op (exit 0)" 'enrich remove --root "$N" | grep -q "nothing to remove"'

# --- removal refusals ---
fresh; enrich span --root "$N" --file lib/orders.js --function checkout "${SPAN[@]}" >/dev/null
python3 - "$N/lib/orders.js" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
s = s.replace("  const lines = await loadLines(cartId);\n", "  const lines = await loadLines(cartId);\n  otelSpan.setAttribute('cart.lines', lines.length);\n")
open(p, "w").write(s)
PY
refused "node: removal is refused while the user's own line still uses otelSpan" "$N" "still uses .otelSpan." remove --root "$N"
fresh; enrich span --root "$N" --file lib/orders.js --function checkout "${SPAN[@]}" >/dev/null
python3 - "$N/lib/orders.js" <<'PY'
import sys
p = sys.argv[1]; lines = open(p).read().splitlines(keepends=True)
i = max(n for n, l in enumerate(lines) if "enrich end orders-checkout" in l)
del lines[i]
open(p, "w").writelines(lines)
PY
refused "node: a begin marker without its end is refused, for remove" "$N" "no matching end" remove --root "$N"
refused "node: ... and for a new span in that file" "$N" "no matching end" span --root "$N" --file lib/orders.js --function loadLines --span-name x.y --tracer-name t

# --- span refusals: each writes nothing ---
fresh
refused "node: a generator is refused" "$N" "generator" span --root "$N" --file lib/orders.js --function batches --span-name a.b --tracer-name t
refused "node: an expression-bodied arrow function is refused" "$N" "expression body" span --root "$N" --file lib/orders.js --function subtotal --span-name a.b --tracer-name t
refused "node: a one-line function is refused (an insert-only edit can't split a line)" "$N" "same line" span --root "$N" --file lib/orders.js --function oneLine --span-name a.b --tracer-name t
refused "node: an unknown function is refused" "$N" "no function named" span --root "$N" --file lib/orders.js --function nope --span-name a.b --tracer-name t
refused "node: an ambiguous name is refused and lists the lines" "$N" "defined 2 times.*lines 6, 16" span --root "$N" --file lib/pricing.js --function total --span-name a.b --tracer-name t
refused "node: a constructor is refused" "$N" "constructor" span --root "$N" --file lib/pricing.js --function Pricing.constructor --span-name a.b --tracer-name t
refused "node: a name that only appears in a regex or a string is not a function" "$N" "no function named" span --root "$N" --file lib/orders.js --function not --span-name a.b --tracer-name t
refused "node: a span name that could break out of the string is refused" "$N" "span name" span --root "$N" --file lib/orders.js --function checkout --span-name "x'); evil(" --tracer-name t
refused "node: a file outside the project root is refused" "$N" "outside the project root" span --root "$N" --file ../escape.js --function f --span-name a.b --tracer-name t
mkdir -p "$N/node_modules/dep"; cp "$N/lib/orders.js" "$N/node_modules/dep/index.js"
refused "node: a dependency under node_modules is refused" "$N" "node_modules" span --root "$N" --file node_modules/dep/index.js --function checkout --span-name a.b --tracer-name t
rm -rf "$N/node_modules"
cp tests/snapshots/instrument/nodejs/tracing.js "$N/tracing.js"
refused "node: the generated bootstrap is refused" "$N" "otel-as-code generated" span --root "$N" --file tracing.js --function shutdown --span-name a.b --tracer-name t
rm "$N/tracing.js"
printf 'function f(a: number): number {\n  return a;\n}\n' > "$N/lib/x.ts"
refused "node: TypeScript is refused as not supported yet" "$N" "TypeScript" span --root "$N" --file lib/x.ts --function f --span-name a.b --tracer-name t
rm "$N/lib/x.ts"
printf 'const otelTracer = 1;\nfunction f() {\n  return otelTracer;\n}\nmodule.exports = { f };\n' > "$N/lib/clash.js"
refused "node: a file that already uses one of the added names is refused" "$N" "already uses the name" span --root "$N" --file lib/clash.js --function f --span-name a.b --tracer-name t
rm "$N/lib/clash.js"
printf 'function f() {\n  return (;\n}\n' > "$N/lib/broken.js"
refused "node: a file that does not parse before the edit is refused" "$N" "does not parse before" span --root "$N" --file lib/broken.js --function f --span-name a.b --tracer-name t
rm "$N/lib/broken.js"
enrich span --root "$N" --file lib/orders.js --function checkout "${SPAN[@]}" >/dev/null
refused "node: the same id twice in a file is refused" "$N" "already has an enrichment with id" span --root "$N" --file lib/orders.js --function loadLines "${SPAN[@]}"
refused "node: a function that is already wrapped is refused" "$N" "already has an enrichment block" span --root "$N" --file lib/orders.js --function checkout --span-name orders.again --tracer-name t
enrich remove --root "$N" >/dev/null

# --- --line, ES modules, CRLF ---
check "node: --line picks one of two definitions with the same name" \
  'enrich span --root "$N" --file lib/pricing.js --function total --line 16 --span-name pricing.count --tracer-name t >/dev/null && sed -n "/^function total/,/^}/p" "$N/lib/pricing.js" | grep -q "pricing.count"'
enrich remove --root "$N" >/dev/null
cat > "$N/lib/files.mjs" <<'JS'
#!/usr/bin/env node
/*
 * Header comment.
 */

import fs from 'node:fs';
import {
  join,
} from 'node:path';

export async function load(dir) {
  const text = await fs.promises.readFile(join(dir, 'x'), 'utf8');
  return text.length;
}
JS
enrich span --root "$N" --file lib/files.mjs --function load --span-name files.load --tracer-name t >/dev/null
check "node: an ES module gets import, placed after its header and its last import" \
  'grep -q "^import { trace as otelTrace, SpanStatusCode as OtelStatus } from .@opentelemetry/api.;" "$N/lib/files.mjs" && [ "$(grep -n "enrich begin otel-tracer" "$N/lib/files.mjs" | cut -d: -f1)" = 10 ]'
printf 'function f(a) {\r\n  return a + 1;\r\n}\r\nmodule.exports = { f };\r\n' > "$N/lib/crlf.js"
enrich span --root "$N" --file lib/crlf.js --function f --span-name crlf.f --tracer-name t >/dev/null
check "node: CRLF line endings are kept on every added line" \
  'python3 -c "import sys; t=open(sys.argv[1],\"rb\").read(); sys.exit(0 if t.count(b\"\\n\") == t.count(b\"\\r\\n\") and b\"enrich begin crlf-f\\r\\n\" in t else 1)" "$N/lib/crlf.js"'

# ================================================================== Python
mkdir -p "$P/pkg"
cp fixtures/python-greenfield/app.py "$P/app.py"
cp tests/snapshots/instrument/python/requirements.txt "$P/requirements.txt"
cat > "$P/pkg/svc.py" <<'PYSRC'
"""Service module."""
from __future__ import annotations

import asyncio
import os


async def fetch(sku):
    await asyncio.sleep(0.001)
    return sku.upper()


class Repo:
    @staticmethod
    def load(sku):
        if sku == "bad":
            raise ValueError("no such sku")
        return {"sku": sku}

    def stream(self):
        yield 1


def outer():
    def inner(x):
        return x * 2
    return inner(21)


def twice():
    return 1


def twice():  # noqa: F811
    return 2
PYSRC
cp "$P/app.py" "$TMPD/app.orig.py"; cp "$P/pkg/svc.py" "$TMPD/svc.orig.py"
out=$(enrich span --root "$P" --file app.py --function reserve_stock --span-name inventory.reserve_stock --tracer-name inventory-api); rc=$?
check "python: span applies and the edit is insert-only" '[ "$rc" -eq 0 ] && insert_only "$TMPD/app.orig.py" "$P/app.py"'
check "python: the decorator sits directly above the def, below the route decorator" \
  'python3 -c "
import sys
l = open(sys.argv[1]).read().splitlines()
i = l.index(\"def reserve_stock(update: StockUpdate):\")
assert l[i-1] == \"# otel-as-code: enrich end inventory-reserve-stock\", l[i-1]
assert l[i-2] == \"@_otel_tracer.start_as_current_span(\\\"inventory.reserve_stock\\\")\", l[i-2]
assert l[i-4] == \"@app.post(\\\"/inventory/reserve\\\")\", l[i-4]
" "$P/app.py"'
check "python: the tracer goes after the last leading import" \
  '[ "$(grep -n "enrich begin otel-tracer" "$P/app.py" | cut -d: -f1)" = 5 ]'
check "python: no dependency note when the SDK is already a declared dependency" '! echo "$out" | grep -q "^dependency:"'
enrich span --root "$P" --file pkg/svc.py --function fetch --span-name svc.fetch --tracer-name svc >/dev/null
enrich span --root "$P" --file pkg/svc.py --function Repo.load --span-name repo.load --tracer-name svc >/dev/null
enrich span --root "$P" --file pkg/svc.py --function outer.inner --span-name svc.inner --tracer-name svc >/dev/null
check "python: the tracer goes after the docstring, __future__ and the imports" \
  'python3 -c "
import sys
l = open(sys.argv[1]).read().splitlines()
assert l[5] == \"# otel-as-code: enrich begin otel-tracer\", l[5]
assert l[4] == \"import os\"
" "$P/pkg/svc.py"'
check "python: a static method's decorator goes under @staticmethod, at the method's indent" \
  'grep -B4 "    def load(sku):" "$P/pkg/svc.py" | head -2 | tr -d "\n" | grep -q "    @staticmethod    # otel-as-code: enrich begin repo-load"'
refused "python: a generator is refused" "$P" "generator" span --root "$P" --file pkg/svc.py --function Repo.stream --span-name a.b --tracer-name t
refused "python: an ambiguous name is refused and lists the lines" "$P" "defined 2 times" span --root "$P" --file pkg/svc.py --function twice --span-name a.b --tracer-name t
refused "python: an unknown function is refused" "$P" "no function named" span --root "$P" --file pkg/svc.py --function nope --span-name a.b --tracer-name t
refused "python: a function that is already wrapped is refused" "$P" "already has an enrichment block" span --root "$P" --file pkg/svc.py --function fetch --span-name svc.again --tracer-name t
check "python: the enriched files pass semconv-lint in strict mode" 'lint_ok "$P/app.py" && lint_ok "$P/pkg/svc.py"'

# The enriched module, run against a stub opentelemetry package whose decorator records calls.
mkdir -p "$P/opentelemetry"
: > "$P/opentelemetry/__init__.py"
cat > "$P/opentelemetry/trace.py" <<'PYSTUB'
import functools, inspect
SPANS = []
class _Tracer:
    def __init__(self, scope): self.scope = scope
    def start_as_current_span(self, name):
        def deco(fn):
            if inspect.iscoroutinefunction(fn):
                @functools.wraps(fn)
                async def wrapper(*a, **k):
                    rec = {"scope": self.scope, "name": name, "error": False}; SPANS.append(rec)
                    try:
                        return await fn(*a, **k)
                    except Exception:
                        rec["error"] = True; raise
                return wrapper
            @functools.wraps(fn)
            def wrapper(*a, **k):
                rec = {"scope": self.scope, "name": name, "error": False}; SPANS.append(rec)
                try:
                    return fn(*a, **k)
                except Exception:
                    rec["error"] = True; raise
            return wrapper
        return deco
def get_tracer(scope): return _Tracer(scope)
PYSTUB
pyrun=$(cd "$P" && python3 -c "
import asyncio, json
from pkg import svc
from opentelemetry.trace import SPANS
a = asyncio.run(svc.fetch('ab'))
b = svc.Repo.load('x')
try:
    svc.Repo.load('bad'); threw = False
except ValueError as e:
    threw = str(e)
c = svc.outer()
print(json.dumps({'a': a, 'b': b, 'threw': threw, 'c': c, 'names': [s['name'] for s in SPANS],
                  'errors': [s['name'] for s in SPANS if s['error']], 'scope': sorted({s['scope'] for s in SPANS})}))" 2>&1)
check "python: enriched functions return what they returned before (async, static, nested)" \
  'echo "$pyrun" | grep -q "\"a\": \"AB\", \"b\": {\"sku\": \"x\"}, \"threw\": \"no such sku\", \"c\": 42"'
check "python: each call made its span, and the failing one is the one marked as an error" \
  'echo "$pyrun" | grep -q "\"names\": \[\"svc.fetch\", \"repo.load\", \"repo.load\", \"svc.inner\"\], \"errors\": \[\"repo.load\"\], \"scope\": \[\"svc\"\]"'
rm -rf "$P/opentelemetry" "$P/pkg/__pycache__"

check "python: remove restores both files byte for byte" \
  'enrich remove --root "$P" | grep -q "^OK: removed 4 enrichment(s) from 2 file(s)" && cmp -s "$P/app.py" "$TMPD/app.orig.py" && cmp -s "$P/pkg/svc.py" "$TMPD/svc.orig.py"'
enrich span --root "$P" --file pkg/svc.py --function fetch --span-name svc.fetch --tracer-name svc >/dev/null
python3 - "$P/pkg/svc.py" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
open(p, "w").write(s + "\n\nMY_TRACER = _otel_tracer\n")
PY
refused "python: removal is refused while the user's own line still uses _otel_tracer" "$P" "still uses ._otel_tracer." remove --root "$P"
rm -rf "$P/reqless"; mkdir -p "$P/reqless"; printf 'flask\n' > "$P/reqless/requirements.txt"; printf 'def f():\n    return 1\n' > "$P/reqless/m.py"
out=$(enrich span --root "$P" --file reqless/m.py --function f --span-name m.f --tracer-name t --dry-run)
check "python: the dependency note appears when no OpenTelemetry package is declared" \
  'echo "$out" | grep -q "^dependency: add \"opentelemetry-api\" to reqless/requirements.txt"'

echo
echo "enrich: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
