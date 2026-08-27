# E2E Validation Harness

Proves the plugin's frozen **generated output** actually works, not just that it
validates syntactically. Three independent checks, numbered per the design's MVP
acceptance criteria (see `DESIGN.md`):

- **#1 — trace flow.** The golden agent Collector config
  (`tests/snapshots/collector/otelcol-agent.yaml.snap`) routes real OTLP traffic
  from the golden Node.js and Python SDK bootstraps, through the *actual* golden
  Collector config, into Jaeger — and the resulting traces carry the correct
  `service.*` resource attributes. Run locally:

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
   so the fixture itself stays untouched.
2. Brings up `docker-compose.yml`: `jaeger` (native OTLP receiver on `:4317`),
   `collector` (the golden agent config, exporting to `jaeger:4317`), `node-app`
   (checkout-api, golden bootstrap, publishes `3000:3000`) and `python-app`
   (inventory-api, golden bootstrap, publishes `8000:8000`).
3. Drives load against **both** apps from the host, over the published ports —
   `curl` against `localhost:3000` and `localhost:8000` — every wait (app
   readiness, trace poll) is bounded so a hung stack can't hang CI.
4. Asserts, via `assert-traces.sh` against Jaeger's query API on
   `localhost:16686`, that both services produced traces with the expected
   `service.*` attributes:
   - `checkout-api`: `service.name=checkout-api,service.version=1.4.2,service.namespace=storefront`
   - `inventory-api`: `service.name=inventory-api,service.version=0.3.1,service.namespace=storefront,deployment.environment.name=e2e`
5. Always tears down: a `trap ... EXIT` dumps `docker compose logs` for the
   collector and both apps, runs `docker compose down -v --remove-orphans`, and
   removes `tests/e2e/.work/` — regardless of whether the assertions passed.

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

## Fixtures stay pristine

`fixtures/nodejs-greenfield/` and `fixtures/python-greenfield/` are never written
to. `run.sh` copies them into `tests/e2e/.work/` (gitignored, recreated and
removed on every run) and layers the golden generated artifacts on top of the
copies there.
