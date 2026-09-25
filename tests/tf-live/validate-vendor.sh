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
    # Both halves are required. The module's grafana_url default is the placeholder
    # https://example.grafana.net, so a token without a URL would apply against nothing.
    grafana)  [ -n "${GRAFANA_URL:-}" ] && [ -n "${GRAFANA_SERVICE_ACCOUNT_TOKEN:-}" ] ;;
    # Datadog needs BOTH keys: the API key authenticates the org, but resource CRUD
    # (dashboards, monitors, SLOs) is rejected with only an API key.
    datadog)  [ -n "${DATADOG_API_KEY:-}" ] && [ -n "${DATADOG_APP_KEY:-}" ] ;;
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
  grafana)
    export TF_VAR_grafana_url="$GRAFANA_URL"
    export TF_VAR_grafana_service_account_token="$GRAFANA_SERVICE_ACCOUNT_TOKEN"
    # Same shape as New Relic's entity GUID: the module CREATES its folder and dashboard, but
    # grafana_rule_group and grafana_slo REFERENCE an existing Prometheus datasource by UID, and
    # Grafana validates that UID when an alert rule is created (a dashboard is stored as opaque
    # JSON and would not complain). The default `grafanacloud-prom` is the Grafana Cloud
    # convention and is wrong for most self-hosted stacks — set this to your stack's UID, or the
    # alert-rule apply fails. That failure is a real finding, not harness noise.
    [ -n "${GRAFANA_PROMETHEUS_DATASOURCE_UID:-}" ] && \
      export TF_VAR_prometheus_datasource_uid="$GRAFANA_PROMETHEUS_DATASOURCE_UID"
    ;;
  datadog)
    export TF_VAR_datadog_api_key="$DATADOG_API_KEY"
    export TF_VAR_datadog_app_key="$DATADOG_APP_KEY"
    # datadoghq.eu / us3 / us5 / ddog-gov.com all need this; the module builds api_url from it.
    [ -n "${DATADOG_SITE:-}" ] && export TF_VAR_datadog_site="$DATADOG_SITE"
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
