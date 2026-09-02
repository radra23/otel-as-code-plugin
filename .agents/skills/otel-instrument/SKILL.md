---
name: otel-instrument
description: Generate OpenTelemetry SDK bootstrap (Node.js / Python), Java agent config, or .NET SDK wiring, plus OTLP wiring for a service. Use when adding OTel instrumentation to a codebase.
---

# otel-instrument (Codex bridge)

> **Requires the otel-as-code repo.** The `commands/` / `skills/` / `agents/` files referenced below live there — if they're not present in your workspace, stop and tell the user to add the repo (see AGENTS.md).

Follow the canonical procedure in this repo — it is the single source of truth:

1. Read `commands/otel-instrument.md` (repo root) and execute its steps.
2. Apply these knowledge skills as you go: `skills/language-maturity/SKILL.md` (gate signals by
   maturity / `--experimental`) and `skills/semconv-discipline/SKILL.md` (conformant output).
3. Codex has no subagent dispatch: if the context cache is stale/absent, `otel-instrument.md`
   runs `/otel-init` logic inline — read `agents/repo-context-scanner.md` and run that scan
   first. Then where it runs the `instrumentation-gen` agent, read `agents/instrumentation-gen.md`
   and generate the bootstrap files yourself.

Two steps deserve care because getting them wrong writes code that cannot run:

- **Step 2 selects a service, not just a language.** Filter to services with
  `instrumentable: true` and prompt when more than one qualifies; never fall back to
  `services[0]`. A browser SPA reports `language: nodejs` with `runtime: browser` — refuse it
  with its `instrumentableReason` rather than generating a Node bootstrap for a bundle.
- **Step 4 finds the existing bootstrap via `existingOtel.bootstrapFiles`**, then by globbing the
  service subtree — not by testing for `tracing.js` in the service root. That test misses
  `api/src/tracing.ts` and writes a second, competing bootstrap beside the real one.

Args: `$ARGUMENTS` (e.g. `python --experimental`, `--service api`, `--fix SC-2,SH-1`, `--force`).

Codex note: `.codex/hooks.json` enforces write-guard + semconv-lint here — a denied overwrite of
an existing bootstrap means regenerate deliberately. `--force` is a full regeneration: read the
files first and carry their deliberate local decisions across, or use `--fix <ids>` to apply
specific `/otel-evaluate` findings in place instead.
