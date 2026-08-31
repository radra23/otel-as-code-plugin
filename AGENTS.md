# AGENTS.md — otel-as-code

Cross-agent instructions for this repo, read by Codex (and other agents that honor
`AGENTS.md`). Claude Code plugin-development specifics live in `CLAUDE.md`.

<!-- Maintainer note: Codex loads this file up to `project_doc_max_bytes` (32 KiB default) —
     keep it lean. An `AGENTS.override.md` beside it, if present, takes precedence. -->

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
  - `write-guard` → PreToolUse: **denies** overwriting an existing generated bootstrap
    (`tracing.*` / `telemetry.*` / `opentelemetry.*` for any supported extension, plus
    `otel-java.env` and `otelcol-*.yaml` — the set is derived in `hooks/otel-paths.sh`) or an
    `infra/observability/<vendor>/*.tf`. A denial means regenerate deliberately.
    `apply_patch` reports paths relative to the session cwd; the guard normalises them before
    matching the `.claude/.otel-force` sentinel, so a relative entry there is honoured.
  - confirm-before-write → PreToolUse: **denies** writing an `otel-context.json` that carries an
    unconfirmed business attribute. NOTE: only whole-file writes are deep-checked; patch-style
    edits are not — so always present business attributes for explicit confirmation. Present
    them already namespaced (`com.myorg.*`); a bare `biz.*` name is a placeholder, never written.
  - `semconv-lint` → PostToolUse: surfaces semconv warnings on OTel file writes (advisory).
  They load automatically when Codex runs with this repo as the git root (the hook commands use
  `git rev-parse --show-toplevel` to find the adapters). SessionEnd/`session-summary` is not
  ported — Codex has SessionEnd, but its PR-changelog output has no natural Codex surface.

## Conventions & architecture
Tool-agnostic conventions — the single-sourced `SEMCONV_VERSION`, the `backends.txt` vendor list,
and the Terraform snapshot layout — plus Claude Code plugin architecture (auto-discovery,
`hooks/hooks.json`, `claude plugin validate`) live in `CLAUDE.md`. Read its "Conventions" section;
they are not restated here, to keep a single source.
