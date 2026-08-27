# otel-as-code

A Claude Code plugin — and a set of Codex skills — for OpenTelemetry instrumentation and observability-as-code.

Instrument any Node.js or Python service, infer service identity from your repo,
generate Terraform for Grafana, Datadog, New Relic, or Dash0 — all from your editor.

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

Pinned to **1.27.0** (stable), defined once as `SEMCONV_VERSION` in the `semconv-discipline`
skill — the single place to bump on a semconv release. Pass `--experimental` to unlock
pre-Stable conventions.

## License

Apache-2.0 — aligned with the OpenTelemetry ecosystem.
