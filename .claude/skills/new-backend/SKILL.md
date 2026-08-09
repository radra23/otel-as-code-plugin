---
name: new-backend
description: Scaffold a new observability backend (vendor) for otel-as-code across the vendor list, the terraform-patterns skill, the terraform-gen subagent, and a terraform-validated golden snapshot. Use when adding a vendor such as honeycomb or dynatrace.
disable-model-invocation: true
---

# Add a new observability backend to otel-as-code

The machine-readable vendor list has a single source (`backends.txt`). Adding a backend is: register it there, add its per-vendor content, then a validated snapshot. Ask for the vendor name and its Terraform provider source if not given.

## 1. Register the vendor (single source of truth)
Add the vendor name (one per line) to `backends.txt` at the repo root. This is the ONLY place the list is enumerated — the CI `validate-terraform` loop, `tests/check-snapshots.sh`, the `session-summary` hook, and `/otel-backend`'s validation all read it.

## 2. terraform-patterns skill
Add a `## <Vendor>` section to `skills/terraform-patterns.md`: provider `source` + version, auth variables, required resources (dashboard / alerts / SLO), key gotchas, and OTel-specific query examples (PromQL/NRQL/native).

## 3. terraform-gen subagent
Add a `## <Vendor> main.tf` block to `subagents/terraform-gen.md` describing the resources to emit, referencing the skill section.

## 4. Golden snapshot (validated)
Create `tests/snapshots/<vendor>/main.tf.snap`:
- Make it SELF-CONTAINED — declare its own `variable` blocks with defaults — so CI can `terraform validate` `main.tf` standalone (the job copies only `main.tf.snap`).
- For an unfamiliar provider, introspect the real schema instead of guessing: after `terraform init`, run `terraform providers schema -json` to get exact resource names and required fields.
- Validate: copy to a temp dir, `terraform init -backend=false` + `terraform validate` (download a pinned terraform binary if absent). Iterate until it passes; then `terraform fmt`.

## 5. Human-facing docs
Update the backend list in `README.md` and the design docs. No CI or `/otel-backend` command edits are needed for the list itself — those read `backends.txt`.

## Verify
Run `/validate-plugin` and confirm the new snapshot validates and the CI vendor loop stays green.
