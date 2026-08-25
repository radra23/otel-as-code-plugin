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

All `commands/…`, `skills/…/SKILL.md`, and `agents/…` paths in these skills are relative to the
otel-as-code repo root (the directory containing `.agents/` and `.codex/`). If your working
directory is elsewhere, resolve them from `git rev-parse --show-toplevel`.

- Workflows: `$otel-init`, `$otel-instrument`, `$otel-evaluate`, `$otel-collector`,
  `$otel-business-attrs`, `$otel-backend`.
- `$semconv-discipline` — OTel semantic-convention rules (also invoked implicitly when editing
  OTel code).

### Codex differences to respect
- **No subagent dispatch.** Where a `commands/otel-*.md` says "dispatch the `<x>` agent", read
  `agents/<x>.md` and do that work inline yourself.
- **Hooks DO run in Codex.** `.codex/hooks.json` ports the guardrails to Codex's
  `PreToolUse`/`PostToolUse` hooks (matching `apply_patch`/file edits) via thin adapters in
  `hooks/codex/` that reuse the same `hooks/*.sh` logic:
  - `write-guard` → PreToolUse: **denies** overwriting an existing `tracing.js` / `tracing.py`,
    `otelcol-*.yaml`, or `infra/observability/<vendor>/*.tf`. A denial means regenerate deliberately.
  - confirm-before-write → PreToolUse: **denies** writing an `otel-context.json` that carries an
    unconfirmed `biz.*` attribute. NOTE: only whole-file writes are deep-checked; patch-style
    edits are not — so always present business attributes for explicit confirmation.
  - `semconv-lint` → PostToolUse: surfaces semconv warnings on OTel file writes (advisory).
  They load automatically when Codex runs with this repo as the git root (the hook commands use
  `git rev-parse --show-toplevel` to find the adapters). SessionEnd/`session-summary` is not
  ported — Codex has SessionEnd, but its PR-changelog output has no natural Codex surface.

## Conventions (tool-agnostic)
- `SEMCONV_VERSION` in `skills/semconv-discipline/SKILL.md` is the single source of truth for the pinned semconv version.
- `backends.txt` (repo root) is the single source of truth for the supported vendor list.
- Terraform golden snapshots live in `tests/snapshots/<vendor>/main.tf.snap`, are self-contained, and validate with `terraform validate`.

See `CLAUDE.md` for Claude Code plugin architecture (auto-discovery, `hooks/hooks.json`, `claude plugin validate`).
