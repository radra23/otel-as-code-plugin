#!/usr/bin/env bash
# tests/hooks/nextjs-shutdown-flush.test.sh
# Offline half of the #173 contract (tests/e2e/nextjs-sigterm-flush.sh is the runtime half).
# Next's own SIGTERM cleanup exits the process without waiting for OpenTelemetry, so the last batch
# of spans was dropped on every stop. The fix is only real if the generator, /otel-instrument's
# deployment step and the goldens all agree: a handler that flushes, AND NEXT_MANUAL_SIG_HANDLE=true
# in the deployment (the handler alone does not help; verified on a real next start).
set -uo pipefail
cd "$(dirname "$0")/../.."
pass=0; fail=0
check() { if eval "$2"; then echo "PASS: $1"; pass=$((pass+1)); else echo "FAIL: $1"; fail=$((fail+1)); fi; }

GEN="agents/instrumentation-gen.md"
CMD="commands/otel-instrument.md"
G="tests/snapshots/instrument/nextjs"
NEXT=$(sed -n '/^### Next.js (App Router or Pages Router)/,/^## Python Bootstrap/p' "$GEN")   # captured once: grep -q + pipefail would race
has() { grep -qF -- "$1" <<<"$NEXT"; }

check "generator has the Next.js shutdown section, with the issue number" \
  'has "### Shutdown: Next.js owns SIGTERM unless the deployment says otherwise" && has "(#173)"'
check "generator says NEXT_MANUAL_SIG_HANDLE is required, in the deployment environment" \
  'has "NEXT_MANUAL_SIG_HANDLE=true\` is required, and it must be in the deployment environment"'
check "generator says the handler alone does not fix it" \
  'has "The handler alone does NOT fix it"'
check "generator states the trade-off (no server drain)" \
  'has "no longer drains the server before"'
check "generator tells the preferred path to import a Node-only shutdown module under the runtime guard" \
  'has "await import('"'"'./instrumentation.node'"'"')" && has "process.on('"'"'SIGTERM'"'"', () => void stop(0))"'
check "generator replaces the manual path's SIGTERM-only handler with one for both signals" \
  'has "**Replace that section'"'"'s \`SIGTERM\` handler**" && has "process.on('"'"'SIGINT'"'"', () => stop(0))"'
check "generator declares @opentelemetry/api (imported by the shutdown module)" \
  'has "\`\"@opentelemetry/api\"\` to \`dependencies\`"'

check "Step 8 adds NEXT_MANUAL_SIG_HANDLE for framework nextjs and calls it required" \
  'grep -qF "For \`framework: nextjs\`, add one more, and say it is required" "$CMD" && grep -qF "NEXT_MANUAL_SIG_HANDLE = true" "$CMD"'

check "golden register hook loads the Node-only shutdown module under the runtime guard" \
  'grep -qF "NEXT_RUNTIME === \"nodejs\"" "$G/instrumentation.js" && grep -qF "./instrumentation.node.js" "$G/instrumentation.js"'
check "golden shutdown module awaits shutdown, exits, handles both signals, and is bounded" \
  'f="$G/instrumentation.node.js"; grep -qF "shutdown" "$f" && grep -qF "process.exit(code)" "$f" && grep -qF "\"SIGTERM\"" "$f" && grep -qF "\"SIGINT\"" "$f" && grep -qF "5000" "$f"'
check "golden package.json declares @opentelemetry/api" \
  'grep -qE "\"@opentelemetry/api\": \"[0-9]" "$G/package.json"'
check "the compose e2e app sets NEXT_MANUAL_SIG_HANDLE like a real deployment would" \
  'grep -qF "NEXT_MANUAL_SIG_HANDLE: \"true\"" tests/e2e/docker-compose.yml'
check "run.sh seeds the shutdown module into the e2e Next.js app" \
  'grep -qF "instrumentation.node.js" tests/e2e/run.sh'
check "the runtime regression script exists and is wired into CI" \
  'test -f tests/e2e/nextjs-sigterm-flush.sh && grep -qF "nextjs-sigterm-flush.sh" .github/workflows/ci.yml'

echo ""
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
