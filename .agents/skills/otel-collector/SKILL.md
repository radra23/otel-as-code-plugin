---
name: otel-collector
description: Generate an otelcol-contrib Collector config (agent or gateway mode) with cardinality guardrails. Use when setting up an OpenTelemetry Collector.
---

# otel-collector (Codex bridge)

Follow the canonical procedure in this repo — it is the single source of truth:

1. Read `commands/otel-collector.md` (repo root) and execute its steps.
2. Apply `skills/collector-topology/SKILL.md` for pipeline topology, tail-sampling, and the
   cardinality-guardrail patterns.

Args: `$ARGUMENTS` (e.g. `gateway`, `--experimental`; default mode is `agent`).

Codex note: `.codex/hooks.json` enforces write-guard here — a denied overwrite of an existing
`otelcol-agent.yaml` / `otelcol-gateway.yaml` means regenerate deliberately.
