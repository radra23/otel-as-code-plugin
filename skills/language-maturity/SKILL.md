---
name: language-maturity
description: Per-language OTel signal maturity matrix (Stable / Beta / Development) and feature-gating rules. Use before generating OTel SDK code to gate signals by maturity and the --experimental flag.
version: 0.1.0
---

# OTel Language Signal Maturity Matrix

Reference: opentelemetry.io/docs/languages (pinned semconv version: see `SEMCONV_VERSION`
in the `semconv-discipline` skill — the single source of truth)

## Maturity Levels

- **Stable** — API/SDK frozen, safe for production, full semconv coverage
- **Beta** — feature-complete but may have minor API changes
- **Development** — experimental, incomplete, not for production

## MVP Languages (Node.js and Python)

### Node.js
| Signal  | Status | Package                                              |
|---------|--------|------------------------------------------------------|
| Traces  | Stable | `@opentelemetry/sdk-trace-node`                      |
| Metrics | Stable | `@opentelemetry/sdk-metrics`                         |
| Logs    | Stable | `@opentelemetry/sdk-logs` + `@opentelemetry/winston-transport` |
| Auto    | Stable | `@opentelemetry/auto-instrumentations-node`          |

Node.js bootstrap: use `@opentelemetry/sdk-node` (bundles traces + metrics + logs).
OTLP exporter: `@opentelemetry/exporter-trace-otlp-grpc` (prefer gRPC over HTTP).
Semconv constants: `@opentelemetry/semantic-conventions` — use named exports
(`ATTR_SERVICE_NAME`, `ATTR_HTTP_REQUEST_METHOD`, etc.) not raw strings.

### Python
| Signal  | Status | Package                                              |
|---------|--------|------------------------------------------------------|
| Traces  | Stable | `opentelemetry-sdk`                                  |
| Metrics | Stable | `opentelemetry-sdk` (MeterProvider)                  |
| Logs    | Beta   | `opentelemetry-sdk` (LoggerProvider) — warn user     |
| Auto    | Stable | `opentelemetry-instrumentation-*` (per-framework)    |

Python bootstrap: use `opentelemetry-sdk` + `opentelemetry-exporter-otlp-proto-grpc`.
Auto-instrumentation: framework-specific package (e.g. `opentelemetry-instrumentation-fastapi`,
`opentelemetry-instrumentation-django`, `opentelemetry-instrumentation-flask`).

## Feature Gating Rules

When generating code for a signal:
1. Check the maturity level from the table above.
2. **Stable** → generate without warning.
3. **Beta** → generate but prepend a comment: `# Beta signal — API may change in future OTel releases`. Adapt comment syntax to the target language (`//` for Node.js/Go/.NET, `#` for Python/Ruby).
4. **Development** → BLOCK generation unless `--experimental` flag is set. Show:
   `⚠ [signal] for [language] is Development-level and not recommended for production.
    Re-run with --experimental to generate anyway.`

**Partial language support:** If a language has mixed maturity (e.g. Traces=Beta, Logs=Development),
generate the higher-maturity signals and block only the Development-level ones (unless `--experimental`).
Never block an entire SDK generation request because one signal is Development-level.

## v1 Language Additions (not in MVP)

| Language | Traces  | Metrics | Logs        |
|----------|---------|---------|-------------|
| Java     | Stable  | Stable  | Stable      |
| Go       | Stable  | Stable  | Beta        |
| .NET     | Stable  | Stable  | Stable      |
| Ruby     | Beta    | Beta    | Development |
| PHP      | Stable  | Beta    | Development |
| Rust     | Beta    | Beta    | Development |
| Swift    | Beta    | Development | Development |

## --experimental Flag Behavior

When `--experimental` is passed:
- Unlock Development-level signals — generate the code but prepend: `# Experimental — requires --experimental flag` (replaces the beta comment for Development signals).
- Enable experimental semconv attributes (GenAI `gen_ai.*`, profiling `process.*`).
- All generated code must include a comment: `# Experimental — requires --experimental flag`.
