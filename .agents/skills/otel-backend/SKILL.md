---
name: otel-backend
description: Generate a complete Terraform module (dashboards, alerts, SLOs) for one observability backend — grafana, datadog, newrelic, or dash0. Use to produce observability-as-code.
---

# otel-backend (Codex bridge)

Follow the canonical procedure in this repo — it is the single source of truth:

1. Read `commands/otel-backend.md` (repo root) and execute its steps.
2. The accepted vendors come from `backends.txt` (repo root) — the single source of truth.
3. Apply `skills/terraform-patterns/SKILL.md` for the backend's provider patterns and gotchas.
4. Codex has no subagent dispatch: where it says to run the `terraform-gen` agent, read
   `agents/terraform-gen.md` and generate the module (then run `terraform fmt` + `validate`)
   yourself. It never runs `terraform plan`/`apply` — those stay with the user.

Args: `$ARGUMENTS` (e.g. `datadog --kind dashboard`, `grafana --output-dir infra/o11y/grafana`).

Codex note: hooks do not auto-fire — do NOT overwrite existing
`infra/observability/<vendor>/*.tf` without explicit intent.
