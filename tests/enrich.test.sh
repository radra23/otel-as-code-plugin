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

# A symlink in the tree that points outside the project is never read for removal or written.
fresh; mkdir -p "$TMPD/outside"
printf '// otel-as-code: enrich begin x-y\nconst planted = 1;\n// otel-as-code: enrich end x-y\n' > "$TMPD/outside/victim.js"
cp "$TMPD/outside/victim.js" "$TMPD/victim.orig.js"
ln -s "$TMPD/outside/victim.js" "$N/lib/link.js"
check "node: remove and list ignore a symlink that points outside the project" \
  'enrich remove --root "$N" | grep -q "nothing to remove" && enrich list --root "$N" | grep -q "no enrichment found" && cmp -s "$TMPD/outside/victim.js" "$TMPD/victim.orig.js"'
refused "node: span on a symlink that points outside the project is refused" "$N" "outside the project root" span --root "$N" --file lib/link.js --function f --span-name a.b --tracer-name t
rm "$N/lib/link.js"

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

# ================================================================== business metrics
# `enrich.py metric` emits a business metric the user confirmed (tests/enrich/context.json).
CTX="$ROOT/tests/enrich/context.json"
metric() { enrich metric --context "$CTX" "$@"; }
ln_of() { grep -n -F -- "$2" "$1" | head -1 | cut -d: -f1; }   # line number of the first line with this text
OJS=lib/orders.js
M_PLACED=(--name com.example.checkout.order_placed --meter-name enrich-orders)
M_DUR=(--name com.example.checkout.payment_duration --meter-name enrich-orders)
RET="return { cartId, lines, status: 'confirmed' };"

# ---- Node.js
fresh; snap "$N"
out=$(metric --root "$N" --file $OJS --function checkout --at "$(ln_of "$N/$OJS" "$RET")" --where before "${M_PLACED[@]}" --dry-run); rc=$?
check "metric node: --dry-run prints the diff, exits 1, writes nothing" \
  '[ "$rc" -eq 1 ] && echo "$out" | grep -q "^+  otelOrderPlaced.add(1);" && same "$N"'
metric --root "$N" --file $OJS --function checkout --at "$(ln_of "$N/$OJS" "$RET")" --where before "${M_PLACED[@]}" >/dev/null; rc=$?
check "metric node: a counter applies, insert-only" '[ "$rc" -eq 0 ] && insert_only tests/enrich/node-app/lib/orders.js "$N/$OJS"'
check "metric node: kind and unit come from the cache (counter, {order})" \
  'grep -q "^const otelOrderPlaced = otelMeter.createCounter(.com.example.checkout.order_placed., { unit: .{order}. });$" "$N/$OJS"'
check "metric node: the meter block and the instrument sit after the directive, the call site before the return" \
  'sed -n 2p "$N/$OJS" | grep -q "enrich begin otel-meter" && grep -B2 -F "$RET" "$N/$OJS" | head -1 | grep -q "otelOrderPlaced.add(1);"'
metric --root "$N" --file $OJS --function checkout --at "$(ln_of "$N/$OJS" "$RET")" --where before "${M_DUR[@]}" --value "(Date.now() - startedAt) / 1000" >/dev/null
check "metric node: a histogram records the given expression, and reuses the meter block" \
  'grep -q "^  otelPaymentDuration.record((Date.now() - startedAt) / 1000);$" "$N/$OJS" && [ "$(grep -c "enrich begin otel-meter" "$N/$OJS")" = 1 ] && grep -q "createHistogram(.com.example.checkout.payment_duration., { unit: .s., advice: { explicitBucketBoundaries: \[0.005, 0.01, .*, 10\] } });$" "$N/$OJS"'
metric --root "$N" --file $OJS --function checkout --at "$(ln_of "$N/$OJS" "const lines = await loadLines")" --where after --name com.example.checkout.cart_lines --meter-name enrich-orders --value "lines.length" >/dev/null
check "metric node: a gauge with no unit in the cache gets no unit, placed after the named line" \
  'grep -q "^const otelCartLines = otelMeter.createGauge(.com.example.checkout.cart_lines.);$" "$N/$OJS" && grep -A2 "const lines = await loadLines" "$N/$OJS" | tail -1 | grep -q "otelCartLines.record(lines.length);"'
enrich span --root "$N" --file $OJS --function checkout "${SPAN[@]}" >/dev/null
check "metric node: a span can wrap a function that already emits metrics" \
  '[ "$(enrich list --root "$N" | grep -c "metric-com-example-checkout\|orders-checkout")" = 4 ]'
check "metric node: the enriched file passes semconv-lint in strict mode" 'lint_ok "$N/$OJS"'

mkdir -p "$N/node_modules/@opentelemetry/api"
cat > "$N/node_modules/@opentelemetry/api/index.js" <<'JS'
const spans = []; const points = [];
const inst = (kind) => (name, opts) => {
  const rec = (v) => points.push({ kind, name, unit: (opts || {}).unit || null, v });
  return { add: rec, record: rec };
};
module.exports = {
  SpanStatusCode: { ERROR: 2 },
  trace: { getTracer: () => ({ startActiveSpan: (name, fn) => {
    const s = { name, setStatus() {}, recordException() {}, end() {} }; spans.push(s); return fn(s); } }) },
  metrics: { getMeter: (scope) => ({ scope, createCounter: inst('counter'), createHistogram: inst('histogram'), createGauge: inst('gauge') }) },
  _points: points,
};
JS
run=$(cd "$N" && node -e "
const orders = require('./lib/orders'); const api = require('@opentelemetry/api');
(async () => {
  const a = await orders.checkout('c1', false); await orders.checkout('c2', false);
  let threw = false; try { await orders.checkout('c3', true); } catch (e) { threw = true; }
  const p = api._points; const of = (n) => p.filter((x) => x.name.endsWith(n));
  console.log(JSON.stringify({ status: a.status, threw, placed: of('order_placed').map((x) => x.v),
    unit: of('order_placed')[0].unit, dur: of('payment_duration').length,
    durOk: of('payment_duration').every((x) => typeof x.v === 'number' && x.v >= 0 && x.v < 5),
    lines: of('cart_lines').map((x) => x.v) }));
})();" 2>&1)
check "metric node: the counter adds 1 per successful checkout and nothing for the failing one" \
  'echo "$run" | grep -q "\"status\":\"confirmed\",\"threw\":true,\"placed\":\[1,1\],\"unit\":\"{order}\""'
check "metric node: the histogram records a duration in seconds for each success; the gauge records on all three" \
  'echo "$run" | grep -q "\"dur\":2,\"durOk\":true,\"lines\":\[2,2,2\]"'
rm -rf "$N/node_modules"

enrich remove --root "$N" --id metric-com-example-checkout-cart-lines >/dev/null
check "metric node: remove --id takes one metric (instrument and call site), keeps the meter and the rest" \
  '! grep -q "CartLines" "$N/$OJS" && grep -q "enrich begin otel-meter" "$N/$OJS" && grep -q "otelOrderPlaced.add(1);" "$N/$OJS"'
enrich remove --root "$N" --id metric-com-example-checkout-order-placed --id metric-com-example-checkout-payment-duration >/dev/null
check "metric node: the meter block goes with the last metric; the span and its tracer stay" \
  '! grep -q "otelMeter\|otel-meter" "$N/$OJS" && grep -q "enrich begin otel-tracer" "$N/$OJS" && grep -q "orders.checkout" "$N/$OJS"'
enrich remove --root "$N" >/dev/null
check "metric node: after removing everything the file is byte for byte the original" 'cmp -s "$N/$OJS" tests/enrich/node-app/lib/orders.js'

fresh
metric --root "$N" --file $OJS --function checkout --at "$(ln_of "$N/$OJS" "$RET")" --where before "${M_PLACED[@]}" >/dev/null
printf '\nconst again = () => otelOrderPlaced.add(1);\n' >> "$N/$OJS"
refused "metric node: removal is refused while the user's own line still uses the instrument" "$N" "still uses .otelOrderPlaced." remove --root "$N"
fresh
metric --root "$N" --file $OJS --function checkout --at "$(ln_of "$N/$OJS" "$RET")" --where before "${M_PLACED[@]}" >/dev/null
refused "metric node: the same metric twice in a file is refused" "$N" "already emits" metric --context "$CTX" --root "$N" --file $OJS --function checkout --at 9 --where before "${M_PLACED[@]}"
refused "metric node: a line inside an existing enrichment block is refused" "$N" "inside an existing enrichment block" metric --context "$CTX" --root "$N" --file $OJS --function checkout --at "$(ln_of "$N/$OJS" "otelOrderPlaced.add(1);")" --where before "${M_DUR[@]}" --value 1

# The other order: a function that already has a span wrap takes a metric too.
fresh
enrich span --root "$N" --file $OJS --function checkout "${SPAN[@]}" >/dev/null
check "metric node: a metric can be added inside a function that already has a span wrap" \
  'metric --root "$N" --file $OJS --function checkout --at "$(ln_of "$N/$OJS" "$RET")" --where before "${M_PLACED[@]}" >/dev/null && grep -B2 -F "$RET" "$N/$OJS" | head -1 | grep -q "otelOrderPlaced.add(1);"'
check "metric node: ... and removing everything still restores the original" \
  'enrich remove --root "$N" >/dev/null && cmp -s "$N/$OJS" tests/enrich/node-app/lib/orders.js'

# Only what the user confirmed, and only real metrics.
fresh; AT=$(ln_of "$N/$OJS" "$RET")
refused "metric: a name that is not in the cache is refused" "$N" "not a confirmed business attribute" metric --context "$CTX" --root "$N" --file $OJS --function checkout --at "$AT" --where before --name com.example.checkout.invented --meter-name t
refused "metric: an unconfirmed entry is refused" "$N" "not confirmed" metric --context "$CTX" --root "$N" --file $OJS --function checkout --at "$AT" --where before --name com.example.checkout.refunds --meter-name t
refused "metric: a dimension is refused (not emitted from code)" "$N" "dimension" metric --context "$CTX" --root "$N" --file $OJS --function checkout --at "$AT" --where before --name com.example.checkout.customer_tier --meter-name t
refused "metric: a missing cache is refused" "$N" "can.t read the context cache" metric --root "$N" --file $OJS --function checkout --at "$AT" --where before "${M_PLACED[@]}"
refused "metric: a histogram without --value is refused" "$N" "needs --value" metric --context "$CTX" --root "$N" --file $OJS --function checkout --at "$AT" --where before "${M_DUR[@]}"
refused "metric node: a --value that closes the call and adds another is refused" "$N" "not one JavaScript expression" metric --context "$CTX" --root "$N" --file $OJS --function checkout --at "$AT" --where before "${M_DUR[@]}" --value "1); evil("
refused "metric node: a --value with two statements is refused" "$N" "not one JavaScript expression" metric --context "$CTX" --root "$N" --file $OJS --function checkout --at "$AT" --where before "${M_DUR[@]}" --value "1; evil()"
refused "metric node: a --value that is not valid where it lands is refused by the parse check" "$N" "would not parse" metric --context "$CTX" --root "$N" --file $OJS --function checkout --at "$AT" --where before "${M_DUR[@]}" --value "1 +"

# Where the call site may go.
refused "metric node: a line outside the function is refused" "$N" "not inside the body" metric --context "$CTX" --root "$N" --file $OJS --function checkout --at 3 --where before "${M_PLACED[@]}"
refused "metric node: after a return is refused" "$N" "would never run" metric --context "$CTX" --root "$N" --file $OJS --function checkout --at "$AT" --where after "${M_PLACED[@]}"
refused "metric node: after a throw is refused" "$N" "would never run" metric --context "$CTX" --root "$N" --file $OJS --function checkout --at "$(ln_of "$N/$OJS" "throw new Error")" --where after "${M_PLACED[@]}"
refused "metric node: before a closing brace is refused" "$N" "closes a block" metric --context "$CTX" --root "$N" --file $OJS --function checkout --at "$((AT - 1))" --where before "${M_PLACED[@]}"
refused "metric node: after a line that opens a block is refused" "$N" "opens a block" metric --context "$CTX" --root "$N" --file $OJS --function checkout --at "$(ln_of "$N/$OJS" "if (fail) {")" --where after "${M_PLACED[@]}"
cat > "$N/lib/shapes.js" <<'JS'
function build(a, b) {
  const sum = a
    + b;
  const text = `first line
  second line ${a}
  third line`;
  const out = combine(
    sum,
    text,
  );
  return out;
}
function combine(x, y) {
  return [x, y];
}
module.exports = { build };
JS
SH=(--root "$N" --file lib/shapes.js --function build "${M_PLACED[@]}")
refused "metric node: a continuation line of an expression is refused" "$N" "middle of a statement" metric --context "$CTX" "${SH[@]}" --at 3 --where before
refused "metric node: a line inside a template literal is refused" "$N" "middle of a statement" metric --context "$CTX" "${SH[@]}" --at 5 --where before
refused "metric node: a line inside a call's arguments is refused" "$N" "middle of a statement" metric --context "$CTX" "${SH[@]}" --at 9 --where before
check "metric node: the line after a multi-line statement is accepted" \
  'metric "${SH[@]}" --at 10 --where after >/dev/null && grep -A2 "^  );$" "$N/lib/shapes.js" | tail -1 | grep -q "otelOrderPlaced.add(1);"'

# ---- Python
rm -rf "$P"; mkdir -p "$P"; cp fixtures/python-greenfield/app.py "$P/app.py"; cp "$P/app.py" "$TMPD/app.orig.py"
cp tests/snapshots/instrument/python/requirements.txt "$P/requirements.txt"
PRET='return {"reserved": True'
PY_RES=(--name com.example.inventory.reservations --meter-name inventory-api)
PY_QTY=(--name com.example.inventory.reserved_quantity --meter-name inventory-api)
metric --root "$P" --file app.py --function reserve_stock --at "$(ln_of "$P/app.py" "$PRET")" --where before "${PY_RES[@]}" >/dev/null; rc=$?
check "metric python: a counter applies, insert-only" '[ "$rc" -eq 0 ] && insert_only "$TMPD/app.orig.py" "$P/app.py"'
check "metric python: the instrument follows the meter block after the imports; kind and unit from the cache" \
  'python3 -c "
import sys
l = open(sys.argv[1]).read().splitlines()
i = l.index(\"# otel-as-code: enrich begin otel-meter\")
assert i == 4, i
assert l[i+1:i+3] == [\"from opentelemetry import metrics as _otel_metrics\", \"_otel_meter = _otel_metrics.get_meter(\\\"inventory-api\\\")\"]
assert l[i+5] == \"_otel_reservations = _otel_meter.create_counter(\\\"com.example.inventory.reservations\\\", unit=\\\"{reservation}\\\")\", l[i+5]
" "$P/app.py"'
metric --root "$P" --file app.py --function reserve_stock --at "$(ln_of "$P/app.py" "    )")" --where after "${PY_QTY[@]}" --value "update.quantity" >/dev/null
check "metric python: a histogram goes after a multi-line statement, at the statement's indent" \
  'grep -A2 "^    )$" "$P/app.py" | tail -1 | grep -q "^    _otel_reserved_quantity.record(update.quantity)$"'
enrich span --root "$P" --file app.py --function reserve_stock --span-name inventory.reserve_stock --tracer-name inventory-api >/dev/null
check "metric python: a span added afterwards gets its own tracer block, outside the meter block" \
  'python3 -m py_compile "$P/app.py" && [ "$(grep -c "enrich begin otel-tracer\|enrich begin otel-meter" "$P/app.py")" = 2 ]'
out=$(metric --root "$P" --file app.py --function get_stock --at "$(ln_of "$P/app.py" 'return {"sku": sku')" --where before --name com.example.checkout.payment_duration --meter-name t --value "0.01" --dry-run)
check "metric python: a histogram in seconds gets duration bucket boundaries" \
  'echo "$out" | grep -q "create_histogram(\"com.example.checkout.payment_duration\", unit=\"s\", explicit_bucket_boundaries_advisory=\[0.005, 0.01, .*, 10\])$"'
printf 'def h(n):\n    x = n\n    return x\n' > "$P/h.py"
out=$(metric --root "$P" --file h.py --function h --at 2 --where after "${PY_QTY[@]}" --value "n" --dry-run 2>&1)
check "metric python: a histogram in another unit keeps the default buckets and says so" \
  'echo "$out" | grep -q "^note: no bucket boundaries are set for unit .{item}." && echo "$out" | grep -q "create_histogram(\"com.example.inventory.reserved_quantity\", unit=\"{item}\")$"'
rm -f "$P/h.py"
check "metric python: the enriched file passes semconv-lint in strict mode" 'lint_ok "$P/app.py"'
refused "metric python: after a return is refused" "$P" "would never run" metric --context "$CTX" --root "$P" --file app.py --function reserve_stock --at "$(ln_of "$P/app.py" "$PRET")" --where after --name com.example.checkout.order_placed --meter-name t
refused "metric python: after a raise is refused" "$P" "would never run" metric --context "$CTX" --root "$P" --file app.py --function reserve_stock --at "$(ln_of "$P/app.py" "raise HTTPException")" --where after --name com.example.checkout.order_placed --meter-name t
refused "metric python: a line in the middle of a statement is refused" "$P" "does not start a statement" metric --context "$CTX" --root "$P" --file app.py --function reserve_stock --at "$(ln_of "$P/app.py" "update.sku, update.quantity, update.warehouse,")" --where before --name com.example.checkout.order_placed --meter-name t
refused "metric python: a line outside the function is refused" "$P" "does not start a statement" metric --context "$CTX" --root "$P" --file app.py --function reserve_stock --at 1 --where before --name com.example.checkout.order_placed --meter-name t
refused "metric python: a --value that is not one expression is refused" "$P" "not one Python expression" metric --context "$CTX" --root "$P" --file app.py --function get_stock --at "$(ln_of "$P/app.py" "return {\"sku\": sku")" --where before --name com.example.checkout.payment_duration --meter-name t --value "1); evil("

mkdir -p "$P/opentelemetry"; : > "$P/opentelemetry/__init__.py"
cat > "$P/opentelemetry/metrics.py" <<'PYSTUB'
POINTS = []
class _Inst:
    def __init__(self, kind, name, unit): self.kind, self.name, self.unit = kind, name, unit
    def _rec(self, v): POINTS.append((self.kind, self.name, self.unit, v))
    add = record = set = _rec
class _Meter:
    def create_counter(self, name, unit=None): return _Inst("counter", name, unit)
    def create_histogram(self, name, unit=None): return _Inst("histogram", name, unit)
    def create_gauge(self, name, unit=None): return _Inst("gauge", name, unit)
def get_meter(scope): return _Meter()
PYSTUB
cat > "$P/opentelemetry/trace.py" <<'PYSTUB'
class _Tracer:
    def start_as_current_span(self, name): return lambda fn: fn
def get_tracer(scope): return _Tracer()
PYSTUB
mkdir -p "$P/fastapi" "$P/pydantic"
printf 'class HTTPException(Exception):\n    def __init__(self, status_code=500, detail=""): self.status_code = status_code\nclass FastAPI:\n    def __init__(self, **k): pass\n    def get(self, path): return lambda fn: fn\n    post = get\n' > "$P/fastapi/__init__.py"
printf 'class BaseModel:\n    def __init__(self, **k): self.__dict__.update(k)\n' > "$P/pydantic/__init__.py"
pyrun=$(cd "$P" && python3 -c "
import json, app
from opentelemetry.metrics import POINTS
ok = app.reserve_stock(app.StockUpdate(sku='s', quantity=3, warehouse='w'))
try:
    app.reserve_stock(app.StockUpdate(sku='s', quantity=0, warehouse='w')); threw = False
except app.HTTPException:
    threw = True
print(json.dumps({'reserved': ok['reserved'], 'threw': threw, 'points': POINTS}))" 2>&1)
check "metric python: one successful call records the counter once and the quantity; the rejected one records nothing" \
  'echo "$pyrun" | grep -q "\"reserved\": true, \"threw\": true, \"points\": \[\[\"histogram\", \"com.example.inventory.reserved_quantity\", \"{item}\", 3\], \[\"counter\", \"com.example.inventory.reservations\", \"{reservation}\", 1\]\]"'
rm -rf "$P/opentelemetry" "$P/fastapi" "$P/pydantic" "$P/__pycache__"
enrich remove --root "$P" --id inventory-reserve-stock >/dev/null
check "metric python: removing the span keeps both metrics and the meter, and drops the tracer" \
  'grep -q "_otel_reservations.add(1)" "$P/app.py" && grep -q "enrich begin otel-meter" "$P/app.py" && ! grep -q "otel-tracer" "$P/app.py"'
check "metric python: removing the rest restores the file byte for byte" \
  'enrich remove --root "$P" >/dev/null && cmp -s "$P/app.py" "$TMPD/app.orig.py"'
rm -rf "$P/gauge"; mkdir -p "$P/gauge"; printf 'def f(depth):\n    x = depth\n    return x\n' > "$P/gauge/q.py"
out=$(metric --root "$P" --file gauge/q.py --function f --at 2 --where after --name com.example.checkout.cart_lines --meter-name t --value "depth" --dry-run)
check "metric python: a gauge uses create_gauge and set()" \
  'echo "$out" | grep -q "^+_otel_cart_lines = _otel_meter.create_gauge(\"com.example.checkout.cart_lines\")$" && echo "$out" | grep -q "^+    _otel_cart_lines.set(depth)$"'
check "span: an id in the reserved metric- namespace is refused" \
  'msg=$(enrich span --root "$P" --file gauge/q.py --function f --span-name metric.f --tracer-name t 2>&1); [ $? -eq 2 ] && echo "$msg" | grep -q "reserved"'

# A `^...$` check also accepts a value with a newline on the end, which would then be written
# into a marker line or a string literal. The names are matched whole.
nl_refused() {
  local name="$1" words="$2"; shift 2
  rm -rf "$P/nl"; mkdir -p "$P/nl"; printf 'def f(x):\n    return x\n' > "$P/nl/q.py"
  local msg rc
  msg=$(python3 -c '
import subprocess, sys
script, root, *rest = sys.argv[1:]
args = [a.replace("<NL>", chr(10)) for a in rest]
r = subprocess.run([sys.executable, script, "span", "--root", root, "--file", "q.py", "--function", "f"] + args,
                   capture_output=True, text=True)
print(r.stderr + r.stdout)
sys.exit(r.returncode)' "$ROOT/scripts/enrich.py" "$P/nl" "$@" 2>&1); rc=$?
  check "$name" '[ "$rc" -eq 2 ] && echo "$msg" | grep -q -- "$words" && [ "$(cat "$P/nl/q.py")" = "$(printf "def f(x):\n    return x")" ]'
}
nl_refused "span: an id ending in a newline is refused, not written into a marker" "must be lowercase letters" --span-name q.f --tracer-name t --id "x<NL>"
nl_refused "span: a span name ending in a newline is refused by name, not by the parse check" "span name" --span-name "q.f<NL>" --tracer-name t
nl_refused "span: a tracer name ending in a newline is refused by name" "tracer name" --span-name q.f --tracer-name "t<NL>"
rm -rf "$P/nl"

echo
echo "enrich: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
