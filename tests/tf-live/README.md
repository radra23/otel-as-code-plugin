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

## Running it

- **Manually:** Actions → *Terraform live validate (opt-in)* → *Run workflow*.
- **Scheduled:** weekly (Mon 04:17 UTC).

When it first runs green against real accounts, drop the "Terraform is not yet proven against live
vendor backends" caveat from the top-level `README.md` (per the ROADMAP).

## Adding another vendor

1. Add its cred-mapping `case` arm in `validate-vendor.sh` (and its `creds_present` check).
2. Add it to the `matrix.vendor` list and its secrets to `env:` in the workflow.
3. Add it to the offline gating test.
