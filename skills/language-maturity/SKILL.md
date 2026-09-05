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

## Runtime gating — what this matrix is about

Every row below describes a **server-side runtime**. The matrix is indexed by the service's
`runtime` field from the context cache, NOT by `language`: those are different questions, and
conflating them is how a Vite + React SPA (`language: nodejs`, `runtime: browser`) gets a
`@opentelemetry/sdk-node` bootstrap that cannot run and breaks the build.

| `runtime` | In scope? | Notes                                                             |
|-----------|-----------|-------------------------------------------------------------------|
| `node`    | yes       | Node.js row below                                                 |
| `python`  | yes       | Python row below                                                  |
| `jvm`     | yes       | Java agent row below                                              |
| `dotnet`  | yes       | .NET code-based SDK (all signals Stable) — see the .NET row below |
| `browser` | **no**    | Out of scope for the MVP — see "Browser / RUM" below              |
| `go`      | yes       | Go row below (manual `net/http` SDK wiring)                       |
| `ruby`    | yes       | Ruby row below (opentelemetry-instrumentation-all)                |
| `php` `rust` | not yet | v1 additions table at the end                                   |

### Browser / RUM — out of scope, deliberately

Browser instrumentation is a different product: a different SDK
(`@opentelemetry/sdk-trace-web` + `@opentelemetry/auto-instrumentations-web`), a different
delivery path (bundled into the page, not preloaded with `node -r`), a different transport
(OTLP/HTTP with CORS, never gRPC), and a different signal set (document load, resource timing,
user interactions — not inbound HTTP server spans). None of the server-side generation in this
plugin applies to it.

`/otel-instrument` must therefore **refuse** a service with `runtime: browser` and say why,
rather than generating a near-miss. This is stated here as well as in the MVP docs because the
only other way to discover it is to try it.

## Supported Languages (Node.js, Python, Java, .NET, Go, Ruby)

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
| Logs    | Development | `opentelemetry-sdk` (`opentelemetry.sdk._logs`) — gated behind `--experimental` |
| Auto    | Stable | `opentelemetry-instrumentation-*` (per-framework)    |

Python bootstrap: use `opentelemetry-sdk` + `opentelemetry-exporter-otlp-proto-grpc`.
Auto-instrumentation: framework-specific package (e.g. `opentelemetry-instrumentation-fastapi`,
`opentelemetry-instrumentation-django`, `opentelemetry-instrumentation-flask`).

**Logs are Development, not Beta — gated behind `--experimental`.** The OTel *spec* marks the
Logs SDK stable, but the Python *implementation* has not been promoted: the API lives under the
underscore module `opentelemetry.sdk._logs`, the SDK's own signal that it may still change. So
treat Python logs as Development — traces and metrics (both Stable) always generate; the logs
pipeline is emitted only when `--experimental` is set (see the Python logs block in
`instrumentation-gen`). Do not "promote" this to Stable from the spec status alone.

### Java (OpenTelemetry Java agent)
| Signal  | Status | Mechanism                                                    |
|---------|--------|--------------------------------------------------------------|
| Traces  | Stable | Java agent — auto-instruments common libraries               |
| Metrics | Stable | Java agent — auto                                            |
| Logs    | Stable | Java agent — log-appender bridge (Logback / Log4j2 / JUL → OTLP) |
| Auto    | Stable | `opentelemetry-javaagent.jar` (zero-code, JDK 8+)            |

Java uses the OpenTelemetry Java **agent** (`-javaagent:opentelemetry-javaagent.jar`), NOT a
manual SDK bootstrap file: it auto-instruments with no code change. Configure entirely via
`OTEL_*` env vars (`OTEL_SERVICE_NAME`, `OTEL_RESOURCE_ATTRIBUTES`, `OTEL_EXPORTER_OTLP_ENDPOINT`)
— the generator emits an `otel-java.env` file plus a pinned agent download + run command (see the
Java section in `instrumentation-gen`). The agent exports OTLP by default, so per-signal exporter
env (`OTEL_TRACES_EXPORTER=otlp`, etc.) is redundant and omitted. "Logs = Stable" refers to the
log-appender bridge (application logging frameworks → OTLP logs), not arbitrary log collection.

### .NET (code-based SDK)
| Signal  | Status | Mechanism                                                          |
|---------|--------|--------------------------------------------------------------------|
| Traces  | Stable | `OpenTelemetry.Instrumentation.AspNetCore` / `.Http` + OTLP exporter |
| Metrics | Stable | same instrumentation packages, `WithMetrics`                       |
| Logs    | Stable | `builder.Logging.AddOpenTelemetry(...)` (ILogger → OTLP)           |
| DB      | **Beta** | `OpenTelemetry.Instrumentation.EntityFrameworkCore` — see the note below |
| Auto    | n/a    | code-based DI wiring, not a profiler (the zero-code agent is a v1 follow-up) |

.NET uses a **code-based** SDK wired into the DI container — the generator emits a marker-stamped
`OpenTelemetry.cs` (a `public static IServiceCollection AddOtelObservability(...)` extension) and
prints the single `Program.cs` line + `dotnet add package` commands, rather than editing the
user's files (see the .NET section in `instrumentation-gen`). The three core signals (traces,
metrics, logs) via `AspNetCore`/`Http` are Stable, so nothing is gated behind `--experimental`.

**EF Core DB instrumentation is Beta — the one .NET package not on the stable line.**
`OpenTelemetry.Instrumentation.EntityFrameworkCore` — the most common third package for any .NET
service that touches a database — still ships as Beta (`1.17.0-beta.x`) while its
`AspNetCore`/`Http`/core siblings are on stable `1.x`, because DB semantic conventions haven't
fully stabilized upstream. Like Node's incubating `messaging.*` (above), don't wave it through as
"all Stable": if you add it, prepend the Beta comment, and note that it ships
`EmitOldAttributes`/`EmitNewAttributes` toggles for the OLD→NEW DB attribute transition
(`db.name`→`db.namespace`, `db.statement`→`db.query.text`, `db.operation`→`db.operation.name`) —
verify the compiled defaults of the installed version rather than asserting which it emits. Traces + metrics ship in the extension; logs wire on
`builder.Logging` (a separate line) so they are offered as a printed optional add-on rather than
folded into the one-liner. Requires a hosted app (ASP.NET Core / Generic Host); a plain console
app has no `IServiceCollection` and is refused.

### Go

| Signal  | Maturity | Package                                              |
|---------|----------|-------------------------------------------------------|
| Traces  | Stable | `go.opentelemetry.io/otel/sdk` + `otlptracegrpc` (v1.46.0) |
| Metrics | Stable | `go.opentelemetry.io/otel/sdk/metric` + `otlpmetricgrpc` (v1.46.0) |
| Logs    | Beta   | `go.opentelemetry.io/otel/sdk/log` + `otlploggrpc` (v0.22.0) — generated by default (Beta doesn't need `--experimental`), with a Beta comment |
| Auto    | Beta   | `go.opentelemetry.io/contrib/.../otelhttp` (v0.71.0) — `net/http` only |

**Logs are Beta, not Development — generated without `--experimental`.** Unlike Python's
Development-level logs (gated behind `--experimental`), Go's Logs SDK is feature-complete enough
to ship as Beta: generate the `InitOtelLogsBeta` function by default, with the Beta warning
comment, same as Feature Gating Rule 3.

### Ruby

| Signal  | Maturity | Package                                                    |
|---------|----------|-------------------------------------------------------------|
| Traces  | Stable | `opentelemetry-sdk` + `opentelemetry-exporter-otlp` (1.13.0 / 0.35.1) |
| Metrics | Development | same gems — generated only under `--experimental`     |
| Logs    | Development | same gems — generated only under `--experimental`     |
| Auto    | n/a    | `opentelemetry-instrumentation-all` (0.96.0) — auto-detects Rails/Sinatra/Rack/DB drivers/HTTP clients, no per-framework list to maintain |

**Metrics and Logs are both Development — gated behind `--experimental`.** Unlike Go's Beta logs
(generated by default with a warning comment), Ruby's Metrics AND Logs implementations are both
Development-level: BLOCK generation of both unless `--experimental` is set, per Feature Gating
Rule 4 — the same treatment Python's Development-level logs already get.

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
| PHP      | Stable  | Beta    | Development |
| Rust     | Beta    | Beta    | Development |
| Swift    | Beta    | Development | Development |

Browser/RUM is not on this list: it is a scope decision, not a maturity one (the web SDK's
traces are Stable). See "Browser / RUM" above.

## --experimental Flag Behavior

When `--experimental` is passed:
- Unlock Development-level signals — generate the code but prepend: `# Experimental — requires --experimental flag` (replaces the beta comment for Development signals).
- Enable experimental semconv attributes (GenAI `gen_ai.*`, profiling `process.*`).
- All generated code must include a comment: `# Experimental — requires --experimental flag`.
