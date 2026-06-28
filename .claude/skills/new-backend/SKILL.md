---
name: new-backend
description: Scaffold a new observability backend (vendor) for otel-as-code across the terraform-patterns skill, the terraform-gen subagent, and a terraform-validated golden snapshot. Use when adding a vendor such as honeycomb or dynatrace.
disable-model-invocation: true
---

# Add a new observability backend to otel-as-code

Adding a vendor touches three places that must stay in lockstep. Ask for the vendor name and its Terraform provider source if not given.

## 1. terraform-patterns skill
Add a `## <Vendor>` section to `skills/terraform-patterns.md`: provider `source` + version, auth variables, required resources (dashboard / alerts / SLO), key gotchas, and OTel-specific query examples (PromQL/NRQL/native).

## 2. terraform-gen subagent
Add a `## <Vendor> main.tf` block to `subagents/terraform-gen.md` describing the resources to emit, referencing the skill section.

## 3. Golden snapshot (validated)
Create `tests/snapshots/<vendor>/main.tf.snap`:
- Make it SELF-CONTAINED — declare its own `variable` blocks with defaults — so CI can `terraform validate` `main.tf` standalone (the job copies only `main.tf.snap`).
- For an unfamiliar provider, introspect the real schema instead of guessing: after `terraform init`, run `terraform providers schema -json` to get exact resource names and required fields.
- Validate: copy to a temp dir, `terraform init -backend=false` + `terraform validate` (download a pinned terraform binary if absent). Iterate until it passes; then `terraform fmt`.

## 4. Wire it up
- Add the vendor to the accepted set in `commands/otel-backend.md`, and to the `validate-terraform` vendor loop in `.github/workflows/ci.yml`.
- Update the backend list in `README.md` and the design docs.

## Verify
Run `/validate-plugin` and confirm the new snapshot validates and the CI vendor loop stays green.
