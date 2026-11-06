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
| `rust`    | yes       | Rust row below (axum 0.8 or actix-web 4.x; SDK wiring + framework layer) |
| `php`     | yes       | PHP row below (Laravel/Symfony placement, or framework-agnostic)  |

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

## The "Auto" row is the mechanism's maturity, not every bundled package's (#227)

A language's "Auto" row below states the maturity of the auto-instrumentation FRAMEWORK/meta-
package as a whole (e.g. Node's `@opentelemetry/auto-instrumentations-node`, Python's
`opentelemetry-instrumentation-*` family) — not a guarantee that every individual instrumentation
plugin it bundles or that family contains is independently at that same level. A meta-package can
be "Stable" as a mechanism while a specific niche or newly-added instrumentation inside it ships
Beta or Experimental; the .NET row already names the one concrete, verified case of this
(`OpenTelemetry.Instrumentation.EntityFrameworkCore` pinned Beta while its `AspNetCore`/`Http`
siblings are Stable) — the same shape can recur in any ecosystem's auto-instrumentation family,
not only .NET's. Do not read "Auto: Stable" as clearing every per-package pin in
`existingOtel.sdkPackages` without checking: when a specific installed instrumentation package's
version or README states a narrower maturity than the row implies, that package-level claim wins
— report it as an `MB` finding (`brownfield-auditor` dimension 9) the same way the .NET exception
is reported, rather than deferring to this table's broader-brush claim. This table is not a
substitute for checking the specific installed package when something looks pinned below its
siblings; verify against the installed version or its own README before asserting a per-package
maturity this table does not itself enumerate.

## Supported Languages (Node.js, Python, Java, .NET, Go, Ruby, Rust, PHP)

### Node.js
| Signal  | Status | Package                                              |
|---------|--------|------------------------------------------------------|
| Traces  | Stable | `@opentelemetry/sdk-trace-node`                      |
| Metrics | Stable | `@opentelemetry/sdk-metrics`                         |
| Logs    | Development | `@opentelemetry/sdk-logs` + `@opentelemetry/winston-transport` — gated behind `--experimental` |
| Auto    | Stable | `@opentelemetry/auto-instrumentations-node`          |

**Logs are Development, not Stable.** The opentelemetry-js README's feature-status table and
opentelemetry.io both list the JS Logs API and SDK as Development. `sdk-node` bundles the logs
pipeline and turns it on from `OTEL_LOGS_EXPORTER` alone, so the generated bootstrap must default
that variable to `none` unless `--experimental` is set (Feature Gating Rule 4).

Node.js bootstrap: use `@opentelemetry/sdk-node` (bundles traces + metrics, and logs under `--experimental`).
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

### Rust

| Signal  | Maturity | Package                                              |
|---------|----------|-------------------------------------------------------|
| Traces  | Beta   | `opentelemetry_sdk` + `opentelemetry-otlp` (0.33) via `tracing-opentelemetry` (0.34) — generated by default, with a Beta comment |
| Metrics | Stable | `opentelemetry_sdk` + `opentelemetry-otlp` (0.33)     |
| Logs    | Stable | `opentelemetry-appender-tracing` (0.33) — `tracing` events become OTel log records |
| Auto    | Alpha  | axum: `opentelemetry-instrumentation-tower` (0.19, `features = ["axum"]`) — the HTTP server layer, axum 0.8 only. actix-web: `opentelemetry-instrumentation-actix-web` (0.25, `features = ["metrics"]`) — `RequestTracing` + `RequestMetrics` middleware, actix-web 4.x only |

Verified against the opentelemetry-rust 0.33.0 status table. The Metrics and Logs API/SDK are
Stable. Logs flow through `opentelemetry-appender-tracing`, because Rust has no user-facing OTel
logging API and `tracing` is the logging API. The OTLP exporter crate is still RC for both
signals; this plugin treats RC as Stable, so metrics and logs carry no Beta comment. Traces (API,
SDK and OTLP exporter) are Beta: generated without `--experimental`, with the Beta comment
(Feature Gating Rule 3), as Go's logs are.

The crates move together: every `opentelemetry*` crate shares one minor, and
`tracing-opentelemetry` sits one minor ahead of them by design (0.34 pairs with 0.33). Bump them
as a group — the framework-specific layer (tower or the actix-web crate) is independently
versioned and does not belong to that group. The tower crate's `axum` feature is not a default;
without it the server span carries no `http.route` and is named after the method alone. The
actix-web crate's `metrics` feature is likewise not a default; without it only traces generate,
no HTTP server duration metric at all.

**Both framework layers are alpha** (each crate's own README stability row — verified
independently for `opentelemetry-instrumentation-actix-web`, not assumed from the tower crate's
status), the only maintained OTel server layers for their respective frameworks. Both are
generated by default anyway, like Go's Beta `otelhttp`, because without them there are no server
spans (or, for actix-web without the `metrics` feature, no server metrics) at all. The summary
says alpha, so nobody mistakes either for a Stable component. actix-web's layer was chosen over
the more widely-known `tracing-actix-web` specifically because the latter's default root span
bakes in pre-stable HTTP attribute names (`http.method`, `http.status_code`, `http.target`) as
literal field keys in its own macro — not a pin that bumps away, and not something this plugin
attempts to patch with an unverified hand-written `RootSpanBuilder`.

### PHP

| Signal  | Maturity | Package                                                       |
|---------|----------|----------------------------------------------------------------|
| Traces  | Stable | `open-telemetry/sdk` (1.16.1) + `open-telemetry/exporter-otlp` (1.5.0) |
| Metrics | Stable | same SDK/exporter packages                                     |
| Logs    | Stable | `open-telemetry/sdk` + `open-telemetry/opentelemetry-logger-monolog` (1.3.1) bridge |
| Auto    | Stable (mechanism); per-package maturity varies | PECL `opentelemetry` extension (1.4.2) + `open-telemetry/opentelemetry-auto-<framework>` |

Verified against opentelemetry.io/docs/languages/php/'s own status table, which lists Traces,
Metrics, and Logs all as **Stable** — unlike Node (Logs: Development) or Ruby (Metrics+Logs:
Development), **PHP needs no `--experimental` gating for any of the three core signals.** The
opentelemetry-php README publishes no separate status table of its own; opentelemetry.io's page
is the controlling source. Design: #117.

**"Auto" here names a mechanism's maturity, not a blanket per-package guarantee** — the same
caveat the "Auto" row note above already states generally. PHP's auto-instrumentation is a
TWO-LAYER system: the PECL `ext-opentelemetry` extension (`zend_observer`-based, PHP 8.2+ for
full built-in-function observation) is a hook mechanism that does **not** generate traces by
itself (verified: opentelemetry.io/docs/zero-code/php/auto/, "Installing the OpenTelemetry
extension by itself does not generate traces") — it needs an explicit per-framework composer
package layered on top (`open-telemetry/opentelemetry-auto-laravel` 1.10.0,
`-auto-symfony` 1.7.0), each independently versioned and independently maturity-rated by its own
README, same as any other per-package exception this note already asks you to check for.

**Transport default is HTTP/protobuf on `:4318`, not gRPC** — verified from the official
zero-code getting-started example (`OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf`) and from
`open-telemetry/transport-grpc`'s own Packagist listing, which requires a second composer
package plus `ext-grpc`. Same posture as Ruby and Rust's gRPC-avoidance, for the same reason
(heavier dependency tree), departing from this plugin's gRPC-first default for Node/Python/.NET.

**Critical gotcha, verified directly from source** (`src/SDK/Common/Configuration/Defaults.php`
on the `open-telemetry/opentelemetry-php` main branch, not docs prose): the SDK's own compiled
defaults are `OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318` and
`OTEL_{TRACES,METRICS,LOGS}_EXPORTER=otlp` — **"otlp enabled + localhost" is the SDK's own
baked-in default, the opposite of Go/Node/Rust/.NET's no-op-until-configured guarantee**, the
same trap Ruby's SDK has (see the Ruby section above). The generated bootstrap must replicate
Ruby's explicit `none`-unless-configured guard or a PHP service ships silently attempting export
to `localhost` in every environment until configured.

**Framework priority is install-base-derived, not community-confirmed** — issue #117 has zero
comments, so there is no community signal to defer to. Packagist install counts (verified live
at implementation time): `opentelemetry-auto-laravel` ~4.56M installs vs. `-auto-symfony` ~2.58M
vs. `-auto-slim` ~1.30M. Laravel first, Symfony second, a framework-agnostic PSR-15/PSR-18 path
as the fallback for anything else — **PHP has no framework-refusal case**, unlike Rust's
axum/actix-web gate; `generatorSupported` stays `true` for any PHP service with no OTel already
wired, the same shape as Ruby's `opentelemetry-instrumentation-all`.

## Feature Gating Rules

When generating code for a signal:
1. Check the maturity level from the table above.
2. **Stable** → generate without warning.
3. **Beta** → generate but prepend a comment: `# Beta signal — API may change in future OTel releases`. Adapt comment syntax to the target language (`//` for Node.js/Go/.NET/Rust, `#` for Python/Ruby).
4. **Development** → BLOCK generation unless `--experimental` flag is set. Show:
   `⚠ [signal] for [language] is Development-level and not recommended for production.
    Re-run with --experimental to generate anyway.`

**Partial language support:** If a language has mixed maturity (e.g. Traces=Beta, Logs=Development),
generate the higher-maturity signals and block only the Development-level ones (unless `--experimental`).
Never block an entire SDK generation request because one signal is Development-level.

## v1 Language Additions (not in MVP)

| Language | Traces  | Metrics | Logs        |
|----------|---------|---------|-------------|
| Swift    | Stable  | Development | Development |

PHP shipped (#117) — see the PHP row under "Supported Languages" above, not this stub table.

**Swift** (verified against opentelemetry.io and the opentelemetry-swift README). Traces are Stable.
Metrics are Development: the README says they implement an outdated spec and will change. The README
calls Logs "beta quality" while opentelemetry.io lists them as Development, so the row uses the
stricter of the two and Swift logs stay behind `--experimental` until the sources agree.

Browser/RUM is not on this list: it is a scope decision, not a maturity one (the web SDK's
traces are Stable). See "Browser / RUM" above.

## --experimental Flag Behavior

When `--experimental` is passed:
- Unlock Development-level signals — generate the code but prepend: `# Experimental — requires --experimental flag` (replaces the beta comment for Development signals).
- Enable experimental semconv attributes (GenAI `gen_ai.*`, profiling `process.*`).
- All generated code must include a comment: `# Experimental — requires --experimental flag`.
