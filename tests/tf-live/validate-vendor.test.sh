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

VENDOR_ARG="grafana"     run;                       check "grafana w/o creds → exit 0"       '[ "$EC" -eq 0 ]'
                                                    check "grafana w/o creds → SKIP notice"  'printf "%s" "$OUT" | grep -q "^SKIP: grafana"'
VENDOR_ARG="datadog"     run;                       check "datadog w/o creds → exit 0"       '[ "$EC" -eq 0 ]'
                                                    check "datadog w/o creds → SKIP notice"  'printf "%s" "$OUT" | grep -q "^SKIP: datadog"'

# With a credential present the gate must OPEN (no SKIP) — it then fails later here because there
# is no terraform/real API offline, which is fine; we only assert it did not skip.
VENDOR_ARG="dash0"       run DASH0_AUTH_TOKEN=dummy; check "dash0 WITH creds → gate opens (no SKIP)" '! printf "%s" "$OUT" | grep -q "^SKIP:"'

# Both halves required: HALF the credentials must still SKIP, never apply against a placeholder
# URL or get rejected mid-apply for a missing app key. Half-configured is the likely real state
# while someone is setting a vendor up, so it is the case worth pinning.
VENDOR_ARG="grafana"     run GRAFANA_SERVICE_ACCOUNT_TOKEN=dummy
check "grafana token but no URL → still SKIPs"      'printf "%s" "$OUT" | grep -q "^SKIP: grafana"'
VENDOR_ARG="grafana"     run GRAFANA_URL=https://x.grafana.net
check "grafana URL but no token → still SKIPs"      'printf "%s" "$OUT" | grep -q "^SKIP: grafana"'
VENDOR_ARG="grafana"     run GRAFANA_URL=https://x.grafana.net GRAFANA_SERVICE_ACCOUNT_TOKEN=dummy
check "grafana WITH both → gate opens (no SKIP)"    '! printf "%s" "$OUT" | grep -q "^SKIP:"'
VENDOR_ARG="datadog"     run DATADOG_API_KEY=dummy
check "datadog api key but no app key → still SKIPs" 'printf "%s" "$OUT" | grep -q "^SKIP: datadog"'
VENDOR_ARG="datadog"     run DATADOG_APP_KEY=dummy
check "datadog app key but no api key → still SKIPs" 'printf "%s" "$OUT" | grep -q "^SKIP: datadog"'
VENDOR_ARG="datadog"     run DATADOG_API_KEY=dummy DATADOG_APP_KEY=dummy
check "datadog WITH both → gate opens (no SKIP)"    '! printf "%s" "$OUT" | grep -q "^SKIP:"'

# Coverage contract: the workflow matrix, the harness's cred gate, and the golden snapshots are
# three lists that must agree. A vendor added to the matrix without a gate hits the "not wired"
# error at runtime — weeks later, in a scheduled run nobody is watching.
MATRIX_VENDORS="$(sed -n 's/^ *vendor: \[\(.*\)\]/\1/p' .github/workflows/tf-live-validate.yml | tr -d ' ' | tr ',' '\n' | grep .)"
for v in $MATRIX_VENDORS; do
  check "matrix vendor '$v' has a credential gate" "grep -qE '^[[:space:]]+$v\)' $H"
  check "matrix vendor '$v' has a golden snapshot" "[ -f tests/snapshots/$v/main.tf.snap ]"
done
check "matrix covers every backend in backends.txt" \
  '[ -z "$(comm -23 <(sort backends.txt) <(printf "%s\n" $MATRIX_VENDORS | sort))" ]'

echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
