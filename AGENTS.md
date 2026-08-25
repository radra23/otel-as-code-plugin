# AGENTS.md — otel-as-code

Cross-agent instructions for this repo, read by Codex (and other agents that honor
`AGENTS.md`). Claude Code plugin-development specifics live in `CLAUDE.md`.

## What this is
otel-as-code is a toolkit for OpenTelemetry instrumentation and observability-as-code:
instrument a codebase (Node.js / Python), infer service identity from the repo, and generate
vendor-neutral Terraform for Grafana / Datadog / New Relic / Dash0. It ships as a Claude Code
plugin AND as Codex skills.

## Using with Codex
Capabilities are exposed as Codex skills under `.agents/skills/`, discovered when this repo is
the working directory / repo root (or vendored into one). Invoke a workflow explicitly with
`$name`. Each skill is a thin bridge — it points at the canonical procedure in `commands/`,
`skills/`, and `agents/` (the single source of truth), which you read and follow.

- Workflows: `$otel-init`, `$otel-instrument`, `$otel-evaluate`, `$otel-collector`,
  `$otel-business-attrs`, `$otel-backend`.
- `$semconv-discipline` — OTel semantic-convention rules (also invoked implicitly when editing
  OTel code).

### Codex differences to respect
- **No subagent dispatch.** Where a `commands/otel-*.md` says "dispatch the `<x>` agent", read
  `agents/<x>.md` and do that work inline yourself.
- **No auto-firing hooks.** The plugin's guardrails do not run in Codex — apply them manually:
  - Don't overwrite an existing `tracing.js` / `tracing.py`, `otelcol-*.yaml`, or
    `infra/observability/<vendor>/*.tf` without explicit intent (was: `write-guard`).
  - Keep output conformant per `skills/semconv-discipline/SKILL.md` (was: `semconv-lint`).
  - Business attributes are ALWAYS confirmed with the user before writing (was: confirm-before-write).

## Conventions (tool-agnostic)
- `SEMCONV_VERSION` in `skills/semconv-discipline/SKILL.md` is the single source of truth for the pinned semconv version.
- `backends.txt` (repo root) is the single source of truth for the supported vendor list.
- Terraform golden snapshots live in `tests/snapshots/<vendor>/main.tf.snap`, are self-contained, and validate with `terraform validate`.

See `CLAUDE.md` for Claude Code plugin architecture (auto-discovery, `hooks/hooks.json`, `claude plugin validate`).
