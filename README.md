# otel-as-code

[![CI](https://github.com/radra23/otel-as-code-plugin/actions/workflows/ci.yml/badge.svg)](https://github.com/radra23/otel-as-code-plugin/actions/workflows/ci.yml)
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)
[![Claude Code](https://img.shields.io/badge/Claude_Code-plugin-d97757)](https://docs.claude.com/en/docs/claude-code/overview)
[![Codex](https://img.shields.io/badge/Codex-skills-4b5563)](AGENTS.md)
![Status: MVP](https://img.shields.io/badge/status-MVP-e8a33d)

A Claude Code plugin — and a set of Codex skills — for OpenTelemetry instrumentation and observability-as-code.

Instrument any Node.js or Python service, infer service identity from your repo,
generate Terraform for Grafana, Datadog, New Relic, or Dash0 — all from your editor.

```bash
claude plugin marketplace add https://github.com/radra23/otel-as-code-plugin
```

Then run `/otel-init` in Claude Code to scan your repo. Full setup — dev hot-reload and
Codex — under [Installation](#installation).

## Status

**MVP / experimental.** Scope: Node.js + Python instrumentation, and Terraform for four
backends (Grafana, Datadog, New Relic, Dash0).

Generated output is validated for **syntax and schema** — every backend module is
`terraform validate`d in CI, and the OTel SDK/semconv pins are checked against current
releases weekly (see the drift check). It is **not yet proven end-to-end against live
backends or a running Collector**. Before trusting generated code: run `terraform plan` /
`apply` against your own account and confirm traces actually flow. Treat the output as a
reviewed starting point, not turnkey infrastructure.

## Installation

### From the marketplace

```bash
claude plugin marketplace add https://github.com/radra23/otel-as-code-plugin
```

### For development (hot-reload)

```bash
git clone https://github.com/radra23/otel-as-code-plugin
claude --plugin-dir /path/to/otel-as-code-plugin
```

## Using with Codex

The same capabilities ship as **Codex skills** under `.agents/skills/`. Codex discovers them
when this repo is your working directory / repo root (or vendored into one — e.g. a git
submodule). Invoke a workflow with `$name`:

```text
$otel-init            # scan repo, detect services
$otel-business-attrs  # confirm service identity + namespace
$otel-instrument      # generate OTel SDK bootstrap
$otel-collector agent # generate Collector config
$otel-backend datadog # generate Datadog Terraform
```

Each Codex skill is a thin bridge to the canonical `commands/`, `skills/`, and `agents/` files
(one source of truth — no duplicated content). See [`AGENTS.md`](AGENTS.md) for the full Codex
guide. The guardrails DO run in Codex — `.codex/hooks.json` ports write-guard + confirm-before-write
to `PreToolUse` and semconv-lint to `PostToolUse` (via thin adapters in `hooks/codex/` that reuse
the same shell hooks). The one difference to respect: Codex has **no subagent dispatch**, so where
a command says "dispatch the `<x>` agent", read `agents/<x>.md` and do that work inline.

## Quick start

```
/otel-init                  # Scan your repo, detect services
/otel-business-attrs        # Confirm service identity + namespace
/otel-instrument            # Generate OTel SDK bootstrap
/otel-collector agent       # Generate Collector config
/otel-backend datadog       # Generate Datadog Terraform
```

## Commands

| Command | Purpose |
|---|---|
| `/otel-init` | First-run setup: detect services, prime context cache |
| `/otel-instrument [lang]` | SDK bootstrap for Node.js or Python |
| `/otel-evaluate` | Read-only brownfield gap audit |
| `/otel-collector [mode]` | otelcol-contrib config (agent \| gateway) |
| `/otel-business-attrs` | Infer + confirm service identity and business metrics |
| `/otel-backend <vendor>` | Terraform for grafana \| datadog \| newrelic \| dash0 |

## Flags

| Flag | Commands | Effect |
|---|---|---|
| `--experimental` | instrument, collector, backend | Unlock pre-Stable semconv conventions |
| `--force` | instrument, backend | Overwrite existing generated files |
| `--kind` | backend | Emit one artifact: dashboard \| alerts \| slo |
| `--output-dir` | backend | Override default `infra/observability/<vendor>/` |

## What gets generated

**SDK bootstrap** (`tracing.js` or `tracing.py`): OTLP export of traces + metrics to a local Collector. Drop-in for your service entry point.

**Collector config** (`otelcol-agent.yaml` or `otelcol-gateway.yaml`): Ready to run with `otelcol-contrib`. Includes cardinality guardrails.

**Terraform module** (`infra/observability/<vendor>/`): Dashboard, alerts, and SLO for your backend. Run `terraform validate` to verify. `terraform plan` and `apply` are yours to run.

## Context cache

otel-as-code writes `.claude/otel-context.json` (ephemeral, gitignored) and `.claude/otel-services.json` (commit this — it's your team's service map).

## Supported languages (MVP)

Node.js (all signals: Stable) and Python (traces + metrics: Stable; logs: Beta).

v1 will add: Java, Go, .NET, Ruby, PHP, Rust.

## Semconv version

Pinned to **1.44.0** (stable), defined once as `SEMCONV_VERSION` in the `semconv-discipline`
skill — the single place to bump on a semconv release. Pass `--experimental` to unlock
pre-Stable conventions.

## License

Apache-2.0 — aligned with the OpenTelemetry ecosystem.
