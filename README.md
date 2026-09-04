# otel-as-code

[![CI](https://github.com/radra23/otel-as-code-plugin/actions/workflows/ci.yml/badge.svg)](https://github.com/radra23/otel-as-code-plugin/actions/workflows/ci.yml)
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)
[![Claude Code](https://img.shields.io/badge/Claude_Code-plugin-d97757)](https://docs.claude.com/en/docs/claude-code/overview)
[![Codex](https://img.shields.io/badge/Codex-skills-4b5563)](AGENTS.md)
![Status: MVP](https://img.shields.io/badge/status-MVP-e8a33d)
[![Discussions](https://img.shields.io/github/discussions/radra23/otel-as-code-plugin?color=2ea043)](https://github.com/radra23/otel-as-code-plugin/discussions)

A Claude Code plugin — and a set of Codex skills — for OpenTelemetry instrumentation and observability-as-code.

Instrument any Node.js, Python, Java, or .NET service, infer service identity from your repo,
generate Terraform for Grafana, Datadog, New Relic, or Dash0 — all from your editor.

```bash
claude plugin marketplace add https://github.com/radra23/otel-as-code-plugin
claude plugin install otel-as-code@otel-as-code
```

Then run `/otel-init` in Claude Code to scan your repo. (`marketplace add` registers the
source; `plugin install` actually enables the plugin.) Full setup — dev hot-reload and
Codex — under [Installation](#installation).

## Status

**MVP / experimental.** Scope: Node.js, Python, Java, and .NET instrumentation, and Terraform
for four backends (Grafana, Datadog, New Relic, Dash0).

Generated output is validated for **syntax and schema** — every backend module is
`terraform validate`d in CI, and the OTel SDK/semconv pins are checked against current
releases weekly (see the drift check). The Node.js, Python, Java, and .NET instrumentation is
additionally **proven end-to-end in CI**: the generated SDK bootstrap (for Java, the OpenTelemetry
Java agent; for .NET, the generated `OpenTelemetry.cs` wired into a real ASP.NET Core app) exports
through the generated Collector config into a running trace store, asserted on every push (see
[`tests/e2e/`](tests/e2e/)).
The **Terraform is not yet proven against live vendor backends** — before trusting it, run
`terraform plan` / `apply` against your own account. Treat backend modules as a reviewed
starting point, not turnkey infrastructure. An opt-in CI job
([`tf-live-validate`](.github/workflows/tf-live-validate.yml)) applies the golden modules against
real New Relic / Dash0 accounts and tears them down — dormant until account secrets are configured
(see [`tests/tf-live/`](tests/tf-live/)). This caveat comes off once it runs green.

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
| `/otel-instrument [lang]` | SDK bootstrap for Node.js / Python, Java agent config, or .NET SDK wiring |
| `/otel-uninstrument` | Remove the generated SDK bootstrap for a service (marker-gated rollback) |
| `/otel-evaluate` | Read-only brownfield gap audit |
| `/otel-collector [mode]` | otelcol-contrib config (agent \| gateway) |
| `/otel-business-attrs` | Infer + confirm service identity and business metrics |
| `/otel-backend <vendor>` | Terraform for grafana \| datadog \| newrelic \| dash0 |

## Flags

| Flag | Commands | Effect |
|---|---|---|
| `--experimental` | instrument, collector, backend | Unlock pre-Stable semconv conventions |
| `--service <id>` | instrument | Pick the target service instead of being prompted |
| `--fix <ids>` | instrument | Apply only these `/otel-evaluate` findings, in place |
| `--force` | instrument, backend, collector | **Full regeneration** — overwrites hand edits (see below) |
| `--confirm-remove-auth` | collector | Required alongside `--force` (without `--public`) to intentionally strip existing receiver auth |
| `--public` | collector | Collector has no private-network path to its sender(s) — adds receiver auth (`bearertokenauth`); default is unauthenticated |
| `--dry-run` | instrument, backend, collector | Preview without writing; exits non-zero if the output would change (composes in CI) |
| `--kind` | backend | Emit one artifact: dashboard \| alerts \| slo |
| `--output-dir` | backend | Override default `infra/observability/<vendor>/` |

`--force` regenerates a file from scratch; it is not a patch. By the time regeneration is worth
running the bootstrap has usually been hand-refined, so `/otel-instrument` prints what it will
overwrite and asks first. To apply an audit's findings without losing those edits, use
`--fix <ids>` with the finding IDs from the `/otel-evaluate` report. For `/otel-collector`
specifically, `--force` alone refuses to remove existing receiver auth — pair it with `--public`
to keep the auth, or `--confirm-remove-auth` to intentionally downgrade.

## What gets generated

**SDK bootstrap** (`tracing.js` or `tracing.py`): traces + metrics + logs, with the exporter for
each signal selected by the spec's own `OTEL_TRACES_EXPORTER` / `OTEL_METRICS_EXPORTER` /
`OTEL_LOGS_EXPORTER` variables (`otlp` | `console` | `none`). Drop-in for your service entry
point.

Two defaults worth knowing:

- **No endpoint configured → every exporter defaults to `none`,** not `otlp`. The SDKs' own
  default points at `localhost:4317`, which in a deployed environment drops all telemetry while
  a reconnect loop burns CPU. Silence is the safer failure.
- **`OTEL_TRACES_EXPORTER=console` prints spans to stdout** with no collector running, so you can
  see your first span in a minute.

Because of the first one, instrumenting is not the last step: `/otel-instrument` finishes by
naming the deployment config files that need `OTEL_EXPORTER_OTLP_ENDPOINT` and offering to write
the settings.

**Collector config** (`otelcol-agent.yaml` or `otelcol-gateway.yaml`): Ready to run with `otelcol-contrib`. Includes cardinality guardrails.

**Terraform module** (`infra/observability/<vendor>/`): Dashboard, alerts, and SLO for your backend. Run `terraform validate` to verify. `terraform plan` and `apply` are yours to run.

## Context cache

otel-as-code writes `.claude/otel-context.json` (ephemeral, gitignored) and
`.claude/otel-services.json` (commit this — it's your team's service map).

Refreshing the cache is a **merge, not a replace**: a re-scan updates facts read from the repo
and carries over everything you confirmed (business attributes, namespace, resolved service-name
conflicts) untouched. Freshness is keyed to a fingerprint of the service-identity files —
manifests, Dockerfiles, CODEOWNERS — so commits that only touch application code don't trigger a
full re-scan.

If your `.gitignore` ignores all of `.claude/`, `/otel-init` will point out that the service map
is being ignored with it, and offer the `.claude/*` + `!.claude/otel-services.json` rewrite —
git can't un-ignore a file inside an excluded directory.

## Supported languages

Node.js (all signals: Stable) and Python (traces + metrics: Stable; logs: Development, opt-in via
`--experimental`) via a generated
SDK bootstrap (`tracing.js` / `tracing.py`). **Java** (all signals: Stable) via the zero-code
OpenTelemetry Java **agent** — the generator emits an `otel-java.env` + a pinned agent download and
run command, no source file. **.NET** (all signals: Stable) via a code-based SDK — the generator
emits a marker-stamped `OpenTelemetry.cs` (an `AddOtelObservability()` DI extension) plus the one
`Program.cs` line and the `dotnet add package` commands to wire it in; no edit to your existing
`Program.cs` or `.csproj`. Requires a hosted app (ASP.NET Core or Generic Host); a plain console
app is refused with that reason.

v1 will add: Go, Ruby, PHP, Rust.

**Browser / RUM is out of scope.** `/otel-instrument` targets server-side runtimes, and it
selects a *service* (prompting when more than one qualifies) rather than assuming the first one
detected. A browser SPA has `language: nodejs` but `runtime: browser`; the command refuses it
with the reason instead of generating a Node SDK bootstrap that cannot run in a bundle.

## Semconv version

Pinned to **1.44.0** (stable), defined once as `SEMCONV_VERSION` in the `semconv-discipline`
skill — the single place to bump on a semconv release. Pass `--experimental` to unlock
pre-Stable conventions.

## Contributing

Questions, bug reports, and "I ran this on my repo and here is what came out" are all welcome,
and that last one is the most useful thing anyone can send.

- [CONTRIBUTING.md](CONTRIBUTING.md) covers the repo's conventions, the single-source-of-truth
  rules, and how to run the tests locally.
- [ROADMAP.md](ROADMAP.md) shows where this is going, and what it deliberately will not do.
- [Discussions](https://github.com/radra23/otel-as-code-plugin/discussions) is the place for
  questions and half-formed ideas. Issues are for things that are broken or missing.

## License

Apache-2.0 — aligned with the OpenTelemetry ecosystem.
