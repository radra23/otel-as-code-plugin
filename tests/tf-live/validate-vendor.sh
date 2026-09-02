#!/usr/bin/env bash
# tests/tf-live/validate-vendor.sh <vendor>
#
# LIVE Terraform validation for one backend: apply the golden module against a REAL vendor
# account, confirm the provider actually created the resources (readback), then ALWAYS destroy.
# This closes the gap `terraform validate` cannot: offline validate is schema-only and proves
# nothing about whether the vendor API accepts the generated dashboard/alert/SLO on create.
#
# DORMANT BY DEFAULT: if this vendor's credentials are not in the environment (GitHub secrets),
# it SKIPS with a notice and exits 0. It must NEVER run on push/PR — see
# .github/workflows/tf-live-validate.yml (schedule + manual dispatch only); it creates real
# resources that cost quota.
#
# Safety: resources are uniquely named per run (TF_VAR_service_name=otel-live-<vendor>-<run id>)
# so repeated/concurrent runs never collide, and an EXIT trap destroys everything even when apply
# or readback fails — a crashed run leaves nothing behind (or, if destroy itself fails, says so
# loudly with the exact name to hunt for).
set -uo pipefail

VENDOR="${1:?usage: validate-vendor.sh <vendor>}"
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SNAP="$REPO_ROOT/tests/snapshots/$VENDOR/main.tf.snap"

[ -f "$SNAP" ] || { echo "::error::no golden snapshot for '$VENDOR' at $SNAP"; exit 1; }

# --- credential gate: skip cleanly (exit 0) when this vendor's secrets are not configured ---
creds_present() {
  case "$VENDOR" in
    newrelic) [ -n "${NEW_RELIC_ACCOUNT_ID:-}" ] && [ -n "${NEW_RELIC_API_KEY:-}" ] ;;
    dash0)    [ -n "${DASH0_AUTH_TOKEN:-}" ] ;;
    *) echo "::error::live validation is not wired for vendor '$VENDOR' yet (add its cred mapping below)"; return 2 ;;
  esac
}
if ! creds_present; then
  rc=$?
  [ "$rc" -eq 2 ] && exit 1
  echo "SKIP: $VENDOR — credentials not configured (set the secrets to enable). Nothing was applied."
  exit 0
fi

# Unique, identifiable, run-scoped name: a leftover is obviously ours and never collides.
RUN_ID="${GITHUB_RUN_ID:-local$$}"
SVC="otel-live-${VENDOR}-${RUN_ID}"

WORK="$(mktemp -d)"
cp "$SNAP" "$WORK/main.tf"

export TF_IN_AUTOMATION=1 TF_INPUT=0
export TF_VAR_service_name="$SVC"
# Map this vendor's secrets onto the golden module's input variables.
case "$VENDOR" in
  newrelic)
    export TF_VAR_newrelic_account_id="$NEW_RELIC_ACCOUNT_ID"
    export TF_VAR_newrelic_api_key="$NEW_RELIC_API_KEY"
    [ -n "${NEW_RELIC_REGION:-}" ]      && export TF_VAR_newrelic_region="$NEW_RELIC_REGION"
    # The newrelic_service_level resource attaches to an existing entity; a fresh account with no
    # reported service has none. Provide NEW_RELIC_ENTITY_GUID (of any reported service) or the
    # SLO apply will fail — which is itself a real finding this job is meant to surface.
    [ -n "${NEW_RELIC_ENTITY_GUID:-}" ] && export TF_VAR_service_entity_guid="$NEW_RELIC_ENTITY_GUID"
    ;;
  dash0)
    export TF_VAR_dash0_auth_token="$DASH0_AUTH_TOKEN"
    [ -n "${DASH0_URL:-}" ]     && export TF_VAR_dash0_url="$DASH0_URL"
    [ -n "${DASH0_DATASET:-}" ] && export TF_VAR_dash0_dataset="$DASH0_DATASET"
    ;;
esac

cleanup() {
  echo "--- $VENDOR: destroy (always runs, even on failure) ---"
  terraform -chdir="$WORK" destroy -auto-approve -input=false 2>&1 | tail -15 \
    || echo "::warning::$VENDOR destroy reported an error — CHECK the account for leftover resources named '$SVC'"
  rm -rf "$WORK"
}
trap cleanup EXIT

echo "=== $VENDOR: init ==="
terraform -chdir="$WORK" init -input=false 2>&1 | tail -8

echo "=== $VENDOR: apply (creates real resources named '$SVC') ==="
if ! terraform -chdir="$WORK" apply -auto-approve -input=false; then
  echo "::error::$VENDOR apply FAILED — the provider API rejected the generated module. This is exactly the class of break offline 'terraform validate' cannot catch."
  exit 1
fi

echo "=== $VENDOR: readback (resources the provider actually created) ==="
created="$(terraform -chdir="$WORK" state list 2>/dev/null || true)"
printf '%s\n' "$created" | sed 's/^/  /'
n="$(printf '%s\n' "$created" | grep -c .)"
if [ "$n" -lt 1 ]; then
  echo "::error::$VENDOR apply reported success but state is empty — nothing was actually created."
  exit 1
fi
echo "PASS: $VENDOR — the provider accepted and created $n resource(s). Tearing down."
exit 0
