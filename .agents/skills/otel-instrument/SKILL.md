---
name: otel-instrument
description: Generate OpenTelemetry SDK bootstrap (Node.js / Python) and OTLP wiring for a service. Use when adding OTel instrumentation to a codebase.
---

# otel-instrument (Codex bridge)

Follow the canonical procedure in this repo — it is the single source of truth:

1. Read `commands/otel-instrument.md` (repo root) and execute its steps.
2. Apply these knowledge skills as you go: `skills/language-maturity/SKILL.md` (gate signals by
   maturity / `--experimental`) and `skills/semconv-discipline/SKILL.md` (conformant output).
3. Codex has no subagent dispatch: where it says to run the `instrumentation-gen` agent, read
   `agents/instrumentation-gen.md` and generate the bootstrap files yourself.

Args: `$ARGUMENTS` (e.g. `python --experimental`, or `--force`).

Codex note: hooks do not auto-fire here — do NOT overwrite an existing `tracing.js` /
`tracing.py` without explicit intent, and keep output conformant per `semconv-discipline`.
