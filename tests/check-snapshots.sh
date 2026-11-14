#!/usr/bin/env bash
# tests/check-snapshots.sh
# LOCAL developer helper (NOT run by CI): after regenerating TF modules with /otel-backend,
# diff the output against the golden files here. CI instead runs `terraform validate` on each
# self-contained snapshot (the `validate-terraform` job) — it does not regenerate and diff.
# Note: golden snapshots are self-contained (inline variables) while real generation splits
# variables into variables.tf, so a raw diff needs normalisation before it is meaningful.
set -euo pipefail

FAIL=0
FOUND=0

# Vendor list comes from the single source of truth (backends.txt at the repo root).
for vendor in $(cat backends.txt); do
  snap="tests/snapshots/${vendor}/main.tf.snap"
  generated="infra/observability/${vendor}/main.tf"

  if [ ! -f "$snap" ]; then
    # Surface the gap rather than skipping silently — a missing snapshot means this
    # vendor is NOT drift-protected.
    echo "MISSING: $vendor golden snapshot not committed ($snap)"
    continue
  fi
  FOUND=$((FOUND+1))

  if [ ! -f "$generated" ]; then
    echo "FAIL: $generated was not generated"
    FAIL=$((FAIL+1))
    continue
  fi

  if diff -q "$snap" "$generated" > /dev/null 2>&1; then
    echo "PASS: $vendor snapshot matches"
  else
    echo "FAIL: $vendor snapshot differs from generated output"
    diff "$snap" "$generated" || true
    FAIL=$((FAIL+1))
  fi
done

# Local stack (/otel-local, not a backends.txt vendor): run it against fixtures/nodejs-greenfield,
# whose app listens on 3000, so the golden also pins the Grafana remap to host 3001. The compose
# file lands at the repo root and otel-local.env in the service's rootDir (the root, there).
for name in otel-local.compose.yaml otel-local.env; do
  snap="tests/snapshots/local-stack/${name}"
  [ -f "$snap" ] || { echo "MISSING: local-stack golden snapshot not committed ($snap)"; continue; }
  FOUND=$((FOUND+1))
  if [ ! -f "$name" ]; then
    echo "FAIL: $name was not generated"
    FAIL=$((FAIL+1))
  elif diff -q "$snap" "$name" > /dev/null 2>&1; then
    echo "PASS: local-stack $name matches"
  else
    echo "FAIL: local-stack $name differs from generated output"
    diff "$snap" "$name" || true
    FAIL=$((FAIL+1))
  fi
done

echo ""
if [ "$FOUND" -eq 0 ]; then
  echo "ERROR: snapshot drift gate is INACTIVE — no golden files committed under tests/snapshots/."
  echo "Generate a module (e.g. /otel-backend grafana against a fixture) and commit"
  echo "tests/snapshots/<vendor>/main.tf.snap so this gate can actually catch output drift."
  echo "See tests/snapshots/README.md for the procedure."
  exit 1
fi

[ "$FAIL" -eq 0 ] && echo "All $FOUND committed snapshot(s) match." || echo "$FAIL snapshot(s) failed."
exit "$FAIL"
