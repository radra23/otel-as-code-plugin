# Live Terraform validation (opt-in)

Offline `terraform validate` (the `validate-terraform` CI job) checks the golden backend modules
against the provider **schema** — it proves nothing about whether the vendor API actually accepts
the generated dashboard / alert / SLO on create. This directory closes that gap: it **applies**
each golden module against a **real vendor account**, confirms the provider created the resources,
then **destroys** them.

It is **dormant until you configure a vendor account**, and runs only from the
[`tf-live-validate`](../../.github/workflows/tf-live-validate.yml) workflow (weekly schedule +
manual `workflow_dispatch`) — never on push/PR, because it creates real resources and needs
secrets that forks can't see.

## What it does per vendor (`validate-vendor.sh <vendor>`)

1. Copies `tests/snapshots/<vendor>/main.tf.snap` to a temp dir.
2. `terraform init` + `apply -auto-approve`, with `TF_VAR_service_name=otel-live-<vendor>-<run-id>`
   so every resource is uniquely named (no collisions across runs).
3. **Readback:** asserts `apply` succeeded and `terraform state list` shows the resources — proof
   the provider API accepted the create.
4. **`destroy` in an EXIT trap** — always runs, even if apply/readback fails, so a crashed run
   leaves nothing behind. If destroy itself fails, it prints the exact resource name to hunt for.

If a vendor's credentials are absent, the harness prints `SKIP: <vendor>` and exits 0 — so the
matrix is safe to run with only some vendors configured.

## Enabling a vendor — add these repository secrets

**New Relic** (`newrelic`):

| Secret | Required | Notes |
|---|---|---|
| `NEW_RELIC_ACCOUNT_ID` | yes | |
| `NEW_RELIC_API_KEY` | yes | a User API key |
| `NEW_RELIC_REGION` | optional | `US` (default) or `EU` |
| `NEW_RELIC_ENTITY_GUID` | **effectively required** | see caveat below |

> **New Relic SLO caveat.** The golden module's `newrelic_service_level` attaches to an existing
> **entity** (`service_entity_guid`). A brand-new account that has never had a service report to it
> has no entity to attach to, so that resource will fail on apply. Point any throwaway service at
> the account once (so an entity exists), then set `NEW_RELIC_ENTITY_GUID` to its GUID. A failure
> here is a real finding, not a harness bug — it is exactly the kind of create-time break offline
> validate cannot see.

**Dash0** (`dash0`):

| Secret | Required | Notes |
|---|---|---|
| `DASH0_AUTH_TOKEN` | yes | |
| `DASH0_URL` | optional | your Dash0 API endpoint, if not the provider default |
| `DASH0_DATASET` | optional | target dataset, if not the default |

**Grafana** (`grafana`):

| Secret | Required | Notes |
|---|---|---|
| `GRAFANA_URL` | yes | e.g. `https://yourstack.grafana.net` — the module's default is a placeholder |
| `GRAFANA_SERVICE_ACCOUNT_TOKEN` | yes | service account token with dashboard + alerting write |
| `GRAFANA_PROMETHEUS_DATASOURCE_UID` | **effectively required** | see caveat below |

> **Grafana datasource caveat.** The module creates its own folder and dashboard, but
> `grafana_rule_group` and `grafana_slo` *reference* an existing Prometheus datasource by UID, and
> Grafana validates that UID when an alert rule is created — a dashboard is stored as opaque JSON
> and would not complain, so this fails at the alerting resource, not the obvious one. The default
> `grafanacloud-prom` is the Grafana Cloud convention and is wrong for most self-hosted stacks. Set
> this to your stack's actual Prometheus datasource UID (Connections → Data sources → the UID in
> the URL). Same shape as the New Relic caveat above: a failure here is a real finding.

**Datadog** (`datadog`):

| Secret | Required | Notes |
|---|---|---|
| `DATADOG_API_KEY` | yes | org API key |
| `DATADOG_APP_KEY` | yes | application key — resource CRUD is rejected with only an API key |
| `DATADOG_SITE` | optional | `datadoghq.com` (default), `datadoghq.eu`, `us3`/`us5`, `ddog-gov.com` |

> No pre-existing-entity caveat for Datadog: the golden module's SLO is `type = "metric"` with its
> own query, so it does not attach to monitors that have to exist first.

## Running it

- **Manually:** Actions → *Terraform live validate (opt-in)* → *Run workflow*.
- **Scheduled:** weekly (Mon 04:17 UTC).

When it first runs green against real accounts, drop the "Terraform is not yet proven against live
vendor backends" caveat from the top-level `README.md` (per the ROADMAP).

## Adding another vendor

1. Add its cred-mapping `case` arm in `validate-vendor.sh` (and its `creds_present` check).
2. Add it to the `matrix.vendor` list and its secrets to `env:` in the workflow.
3. Add it to the offline gating test.

The gating test enforces steps 1–2 rather than trusting them: it reads `matrix.vendor` out of the
workflow and asserts every entry has both a credential gate and a golden snapshot, and that the
matrix covers all of `backends.txt`. A vendor added to the matrix alone would otherwise fail with
"not wired" weeks later, inside a scheduled run nobody is watching.
