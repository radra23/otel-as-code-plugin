#!/usr/bin/env bash
# Offline: verify plan-local.sh rejects bad input without touching terraform.
set -uo pipefail
cd "$(dirname "$0")/../.."
pass=0; fail=0
check() { if eval "$2"; then echo "PASS: $1"; pass=$((pass+1)); else echo "FAIL: $1"; fail=$((fail+1)); fi; }

check "no vendor -> exit 2" 'bash tests/e2e/plan-local.sh >/dev/null 2>&1; [ $? -eq 2 ]'
check "unknown vendor -> exit 2" 'bash tests/e2e/plan-local.sh bogusvendor >/dev/null 2>&1; [ $? -eq 2 ]'
check "known vendor is accepted past validation" '
  out=$(bash tests/e2e/plan-local.sh grafana 2>&1 || true)
  # passes vendor validation: reaches the terraform step (init/plan or "terraform: not found"),
  # never the "unknown vendor" branch.
  ! printf "%s" "$out" | grep -q "unknown vendor"'

echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
