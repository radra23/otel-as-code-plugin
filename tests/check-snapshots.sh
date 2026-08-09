#!/usr/bin/env bash
# tests/check-snapshots.sh
# Run after generating TF modules — diff against golden files.
# Called by CI after running /otel-backend against greenfield fixture.
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
