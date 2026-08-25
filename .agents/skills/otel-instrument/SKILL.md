---
name: otel-instrument
description: Generate OpenTelemetry SDK bootstrap (Node.js / Python) and OTLP wiring for a service. Use when adding OTel instrumentation to a codebase.
---

# otel-instrument (Codex bridge)

Follow the canonical procedure in this repo — it is the single source of truth:

1. Read `commands/otel-instrument.md` (repo root) and execute its steps.
2. Apply these knowledge skills as you go: `skills/language-maturity/SKILL.md` (gate signals by
   maturity / `--experimental`) and `skills/semconv-discipline/SKILL.md` (conformant output).
3. Codex has no subagent dispatch: if the context cache is stale/absent, `otel-instrument.md`
   runs `/otel-init` logic inline — read `agents/repo-context-scanner.md` and run that scan
   first. Then where it runs the `instrumentation-gen` agent, read `agents/instrumentation-gen.md`
   and generate the bootstrap files yourself.

Args: `$ARGUMENTS` (e.g. `python --experimental`, or `--force`).

Codex note: `.codex/hooks.json` enforces write-guard + semconv-lint here — a denied overwrite of
an existing `tracing.js` / `tracing.py` means regenerate deliberately.
