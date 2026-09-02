#!/usr/bin/env bash
# tests/tf-live/validate-vendor.test.sh
# OFFLINE test of the live-validation harness's GATING logic — the part that must be right for the
# job to stay safely dormant. It never invokes terraform or touches a vendor: it proves the script
# skips cleanly (exit 0) when credentials are absent, opens the gate when they are present, and
# errors on bad input. The apply/destroy path needs real terraform + secrets and is exercised only
# by the opt-in workflow.
set -uo pipefail
cd "$(dirname "$0")/../.."   # repo root
H="tests/tf-live/validate-vendor.sh"
pass=0; fail=0
check() { if eval "$2"; then echo "PASS: $1"; pass=$((pass+1)); else echo "FAIL: $1"; fail=$((fail+1)); fi; }

# Always run with a scrubbed environment (env -i) so a developer's real vendor creds can never
# leak in and change which path the harness takes. OUT/EC are captured immediately after each run.
run() { OUT="$(env -i PATH="$PATH" "$@" bash "$H" ${VENDOR_ARG:-} 2>&1)"; EC=$?; }

VENDOR_ARG=""            run;                       check "no arg → nonzero exit"            '[ "$EC" -ne 0 ]'
VENDOR_ARG="newrelic"    run;                       check "newrelic w/o creds → exit 0"      '[ "$EC" -eq 0 ]'
                                                    check "newrelic w/o creds → SKIP notice" 'printf "%s" "$OUT" | grep -q "^SKIP: newrelic"'
VENDOR_ARG="dash0"       run;                       check "dash0 w/o creds → exit 0"         '[ "$EC" -eq 0 ]'
                                                    check "dash0 w/o creds → SKIP notice"    'printf "%s" "$OUT" | grep -q "^SKIP: dash0"'
VENDOR_ARG="not-a-real-vendor" run;                 check "unknown vendor → nonzero exit"    '[ "$EC" -ne 0 ]'

# With a credential present the gate must OPEN (no SKIP) — it then fails later here because there
# is no terraform/real API offline, which is fine; we only assert it did not skip.
VENDOR_ARG="dash0"       run DASH0_AUTH_TOKEN=dummy; check "dash0 WITH creds → gate opens (no SKIP)" '! printf "%s" "$OUT" | grep -q "^SKIP:"'

echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
