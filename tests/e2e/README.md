# E2E Validation Harness

Proves the plugin's frozen **generated output** actually works, not just that it
validates syntactically. Three independent checks, numbered per the design's MVP
acceptance criteria (see `DESIGN.md`):

- **#1 — trace flow (+ Python `--experimental` logs).** The golden agent Collector
  config (`tests/snapshots/collector/otelcol-agent.yaml.snap`) routes real OTLP
  traffic from the golden Node.js and Python SDK bootstraps, a Java service under
  the OpenTelemetry Java **agent**, AND a Next.js app instrumented via the golden
  `instrumentation.js` register hook (`@vercel/otel`, over OTLP/HTTP), through the
  *actual* golden Collector config, into Jaeger — and the resulting traces carry the
  correct `service.*` resource attributes. The Python app is seeded with the
  `--experimental` bootstrap
  (traces + metrics + the Development-level logs pipeline), and the run additionally
  asserts that a stdlib log it emits is exported as an OTLP **log record** with the
  right `service.name` (proving the #12 logs path end-to-end). Run locally:

  ```bash
  bash tests/e2e/run.sh
  ```

- **#3 — Collector config validity.** The same golden Collector config passes
  `otelcol-contrib validate` (plus a memory_limiter-ordering guard that
  `validate` alone doesn't enforce). Run locally:

  ```bash
  bash tests/collector-validate.sh
  ```

- **#4 — Terraform plan.** A local-only helper that runs `terraform init && plan`
  for one backend's golden snapshot against your own vendor credentials (never
  run in CI — no vendor secrets there). Run locally:

  ```bash
  bash tests/e2e/plan-local.sh <vendor>   # one of the vendors in backends.txt
  ```

In CI, `run.sh` (#1) and `collector-validate.sh` (#3) run in the `e2e` job on
every push/PR. #4 stays local-only.

## What `run.sh` does

1. Seeds throwaway copies of the greenfield fixtures under `tests/e2e/.work/`
   (`fixtures/nodejs-greenfield/`, `fixtures/python-greenfield/` are never
   modified), overlaying the golden instrumented bootstrap + manifest
   (`tests/snapshots/instrument/{nodejs,python}/`) on top. For Python it also
   writes a small `e2e_main.py` entrypoint shim that imports the golden
   `tracing.py` (which sets up the providers as an import side effect) and calls
   `tracing.instrument_fastapi(app)` on the pristine fixture's FastAPI `app`,
   so the fixture itself stays untouched. For Python the seeded `tracing.py` is the
   **`--experimental`** variant (`tracing.experimental.py`), which adds the logs
   pipeline on top of traces + metrics.
   For Java it copies the pristine `fixtures/java-greenfield/App.java` + the golden
   `tests/snapshots/instrument/java/otel-java.env`, and downloads the pinned OTel
   Java agent JAR (v2.31.1) — no source instrumentation; the agent auto-instruments
   the JDK `com.sun.net.httpserver` app at runtime.
   For Next.js it copies the pristine `fixtures/nextjs-greenfield/` App Router app +
   the golden `tests/snapshots/instrument/nextjs/{instrumentation.js,package.json}`
   (the register hook + `@vercel/otel` manifest); the container runs `npm install`,
   `next build`, and `next start`, and Next.js 15 auto-detects `instrumentation.js`.
2. Brings up `docker-compose.yml`: `jaeger` (native OTLP receiver on `:4317`),
   `collector` (the golden agent config **plus** `collector-logs-overlay.yaml`, a
   deep-merged second `--config` that fans the logs pipeline out to a `file` exporter
   writing `.work/collector-out/logs.json` — the golden snapshot is not modified),
   `node-app`
   (checkout-api, publishes `3000:3000`), `python-app` (inventory-api, publishes
   `8000:8000`), `java-app` (payments-api, `eclipse-temurin` JDK running under
   `-javaagent`, publishes `8080:8080`), and `nextjs-app` (web-frontend, exporting to
   the collector's **HTTP** port `4318` since `@vercel/otel` is OTLP/HTTP only,
   publishes `3001:3000`).
3. Drives load against **all four** apps from the host, over the published ports —
   `curl` against `localhost:3000`, `localhost:8000`, `localhost:8080`, and
   `localhost:3001` — every wait (app readiness, trace poll) is bounded so a hung
   stack can't hang CI. The Next.js app gets a larger readiness timeout because it
   runs `npm install` + `next build` inline.
4. Asserts, via `assert-traces.sh` against Jaeger's query API on
   `localhost:16686`, that all four services produced traces with the expected
   `service.*` attributes:
   - `checkout-api`: `service.name=checkout-api,service.version=1.4.2,service.namespace=storefront`
   - `inventory-api`: `service.name=inventory-api,service.version=0.3.1,service.namespace=storefront,deployment.environment.name=e2e`
   - `payments-api`: `service.name=payments-api,service.version=1.0.0,service.namespace=storefront,deployment.environment.name=e2e`
   - `web-frontend` (Next.js): `service.name=web-frontend,service.version=2.1.0,service.namespace=storefront,deployment.environment.name=e2e`
5. Asserts, via `assert-logs.sh` against `.work/collector-out/logs.json`, that the
   Python app's `reserved sku=...` log (emitted on `/inventory/reserve`, bridged to
   OTLP by the `--experimental` bootstrap) arrived as a log record with
   `service.name=inventory-api`.
6. Always tears down: a `trap ... EXIT` dumps `docker compose logs` for the
   collector and both apps, runs `docker compose down -v --remove-orphans`, and
   removes `tests/e2e/.work/` — regardless of whether the assertions passed.

## Expected collector errors (not a failure)

During a `run.sh` run the golden collector config routes **all three** pipelines
(traces/metrics/logs) through the OTLP exporter to Jaeger, but Jaeger's OTLP receiver
only accepts traces. As a result the collector logs `Unimplemented` export-retry
errors for the **metrics** pipeline, and for the **logs** pipeline's OTLP-to-Jaeger
leg, for the whole run — this is **expected and harmless**. (Logs also fan out to the
overlay's `file` exporter, which succeeds; that file leg is what the harness asserts.
Metrics are not asserted.) These lines also show up in the `docker compose logs` tail
the cleanup trap prints on failure, so when diagnosing a failed run, ignore
metrics/logs OTLP export-retry lines and instead look at the trace-export lines, the
`collector-out/logs.json` contents, and the app/collector startup output. (They aren't
filtered out of the log dump on purpose: the exporter carries traces too, so grepping
out "export failed"-shaped lines risks hiding a real trace-export failure.)

## Plaintext OTLP

The collector's exporter to Jaeger and both apps' exporters to the collector are
all plaintext (no TLS) for this local-only stack: the golden Collector config
sets `tls.insecure: true` on its OTLP exporter, and the apps point
`OTEL_EXPORTER_OTLP_ENDPOINT` at `http://collector:4317`. The Python gRPC OTLP
exporter defaults to TLS regardless of an `http://` endpoint scheme, so
`python-app` additionally sets `OTEL_EXPORTER_OTLP_INSECURE=true`.

## Pinned versions

| Component | Version |
|---|---|
| `jaegertracing/all-in-one` | `1.60` |
| `otel/opentelemetry-collector-contrib` | `0.128.0` |
| `node` (base image) | `20-bookworm-slim` |
| `python` (base image) | `3.12-slim-bookworm` |
| `eclipse-temurin` (base image) | `21-jdk-jammy` |
| OTel Java agent | `2.31.1` |
| `next` / `react` (Next.js fixture) | `15.1.12` / `19.0.0` |
| `@vercel/otel` (Next.js instrument snapshot) | `1.14.2` |

## Fixtures stay pristine

`fixtures/nodejs-greenfield/`, `fixtures/python-greenfield/`, and
`fixtures/nextjs-greenfield/` are never written to. `run.sh` copies them into
`tests/e2e/.work/` (gitignored, recreated and removed on every run) and layers the
golden generated artifacts on top of the
copies there.
