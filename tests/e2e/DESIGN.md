# E2E Validation Harness — Design

**Date:** 2026-08-27
**Status:** Approved design, pre-implementation
**Owner:** otel-as-code

## 1. Problem

The MVP ships output that is validated for *syntax and schema* but is, in the
README's own words, "not yet proven end-to-end against live backends or a running
Collector." The design spec's MVP acceptance criteria demand more than validation:

- **#1** — the generated SDK bootstrap exports OTLP to a local Collector and traces
  appear in a trace store with correct `service.*` resource attributes.
- **#3** — the generated Collector config passes `otelcol validate`.
- **#4** — the generated Terraform passes `validate` *and* produces a clean `plan`.

Nothing in the repo currently exercises the SDK → Collector → trace-store path (#1)
or runs `otelcol validate` on a Collector config (#3). This harness closes that gap:
it proves the frozen generated output actually works end-to-end.

## 2. Scope

**In (this increment):**
- #1 trace-flow smoke test in CI, for **both** Node.js and Python.
- #3 `otelcol validate` on the golden **agent** Collector config, in CI.
- #4 a **local-only** `terraform plan` helper script (not CI — no vendor creds there).
- A new `e2e` CI job on push + PR, parallel to the existing fast jobs.

**Out (clean follow-ups, deliberately YAGNI):**
- Live vendor API calls / real `plan` in CI (needs secrets + external dependency).
- Gateway-mode Collector config validation (only agent is exercised here).
- Brownfield E2E, multi-version matrices, logs/metrics-signal assertions.
- Adding `otelcol-contrib` to `scripts/drift_check.py` (noted as a follow-up).

## 3. Approach: validate golden artifacts, not live generation

The slash commands are agent-driven and cannot run headless in CI, so the harness
validates **committed golden artifacts** — the same model the Terraform snapshot
tests already use. Freeze the generated output, prove the frozen output works, and
regenerate manually when the generator changes. Live-generation correctness stays
covered by the existing snapshot-diff discipline.

**The property that makes this a real test, not a mock:** the generated Collector
config already exports OTLP to a configurable endpoint, and Jaeger exposes a native
OTLP receiver on `:4317`. The compose wires the *actual golden config* as
`app → collector → jaeger`, pointing only its OTLP exporter endpoint at Jaeger
instead of a vendor. The same file validated in #3 is the one routing traces in #1.

## 4. Architecture

```
tests/
  e2e/
    DESIGN.md              # this document
    docker-compose.yml     # collector + jaeger + node-app + python-app
    run.sh                 # orchestrate: seed apps -> up -> load -> assert -> teardown
    assert-traces.sh       # poll Jaeger query API, assert service.* on real spans
    plan-local.sh          # #4: terraform plan vs your creds (local only)
    README.md              # what it proves + how to run locally
  snapshots/
    collector/
      otelcol-agent.yaml.snap    # golden generated agent Collector config
    instrument/
      nodejs/tracing.js          # golden generated Node SDK bootstrap
      python/tracing.py          # golden generated Python SDK bootstrap
  collector-validate.sh          # #3: otelcol-contrib validate on the golden config
```

Each unit has one purpose and a clean interface:
- `assert-traces.sh` — input: Jaeger base URL + expected `{service, version, namespace,
  environment}` per app; output: exit 0 if all land within timeout, else 1 with detail.
- `collector-validate.sh` — input: golden config path; output: exit code from
  `otelcol-contrib validate` (with a dummy OTLP endpoint env set).
- `run.sh` — the orchestrator; owns compose lifecycle and teardown.
- `plan-local.sh` — input: vendor + creds from env; output: `terraform plan` result.

## 5. Golden artifacts

- **`otelcol-agent.yaml.snap`** — the generated agent Collector config. OTLP receiver
  on `:4317`; processors per `collector-topology` (batch + cardinality guardrails);
  OTLP exporter to `${OTEL_EXPORTER_OTLP_ENDPOINT}`. Self-contained and env-driven so
  the same file validates standalone (#3) and routes to Jaeger in compose (#1).
- **`instrument/nodejs/tracing.js`, `instrument/python/tracing.py`** — the generated
  SDK bootstraps. Export OTLP to the Collector via the standard
  `OTEL_EXPORTER_OTLP_ENDPOINT` env var. Set `service.name`, `service.version`, and
  the business/identity attrs (`service.namespace`, `deployment.environment`).
  Dependency versions stay in lockstep with `agents/instrumentation-gen.md` — so a bad
  pin bump fails this harness.

The greenfield fixtures (`fixtures/nodejs-greenfield`, `fixtures/python-greenfield`)
remain uninstrumented — they are the plugin's *input*. `run.sh` copies the golden
bootstrap into a throwaway copy of each fixture and loads it the documented way
(`node --require ./tracing.js index.js`; the Python equivalent), so the fixtures on
disk are never mutated.

## 6. #1 — Trace-flow smoke test

1. `run.sh` seeds throwaway app dirs with the golden bootstraps, then `docker compose up -d`.
2. Wait (bounded timeout) for collector + jaeger + both apps to be healthy.
3. Drive load: a handful of `curl`s against each app's HTTP endpoint.
4. `assert-traces.sh` polls Jaeger (`/api/services`, then `/api/traces?service=<name>`)
   for up to ~30s (traces are async), and for **each** service asserts:
   - at least one trace/span landed (the full `app → collector → jaeger` path worked), and
   - resource attributes carry correct `service.*`: `service.name` matches, and
     `service.version` / `service.namespace` / `deployment.environment` are present with
     the fixture's values. (Jaeger exposes resource attrs as process tags — a real
     assertion on what was exported, not a config read.)
5. Teardown always runs (see §9).

## 7. #3 — Collector validate

`tests/collector-validate.sh` runs
`otelcol-contrib validate --config tests/snapshots/collector/otelcol-agent.yaml.snap`
against a **pinned** `otelcol-contrib` binary (downloaded in CI, same pattern as the
pinned `terraform`). Before validating it sets a dummy `OTEL_EXPORTER_OTLP_ENDPOINT`
so env substitution of an unset var can't produce a false failure. Agent config only
in this increment; gateway is a follow-up.

## 8. #4 — Terraform plan (local only)

`tests/e2e/plan-local.sh <vendor>` runs `terraform init && terraform plan` on a
backend module using creds from the environment — the spec's "clean plan against a
real account", made a one-command repeatable step. Not in CI (no vendor creds);
CI keeps the existing `validate-terraform`.

## 9. CI integration, error handling, pins

**CI job** — new `e2e` job in `.github/workflows/ci.yml`, on push + PR, parallel to
the fast jobs so it never slows them:
1. checkout → download pinned `otelcol-contrib`
2. `tests/collector-validate.sh` (#3 — fails early if the config is broken)
3. `tests/e2e/run.sh` (#1 — compose up, load, assert, teardown)

**Error handling** (keeps the job non-flaky and self-cleaning):
- `run.sh` uses `set -euo pipefail` and a `trap … EXIT` that always runs
  `docker compose down -v` — a failed assertion never leaks containers.
- Every wait (health, trace-poll) is bounded by a timeout; CI fails with a message
  rather than hanging.
- On failure, dump `docker compose logs` (collector + both apps) to the CI log so a
  red run is diagnosable without a local repro.

**Pins** (matches the repo's single-source discipline): `otelcol-contrib` version,
Jaeger image tag, and Node/Python base images are pinned literals. Golden-bootstrap
dependency versions track `agents/instrumentation-gen.md`.

## 10. Acceptance criteria (this harness is done when)

1. `tests/collector-validate.sh` passes against the golden agent config with a pinned
   `otelcol-contrib`.
2. `tests/e2e/run.sh` brings up the stack, drives load, and asserts traces for **both**
   Node.js and Python land in Jaeger with correct `service.*` — green locally and in CI.
3. The `e2e` CI job runs on push + PR, in parallel, and always tears down.
4. A failing assertion produces diagnosable output (component logs) and a non-zero exit.
5. `plan-local.sh <vendor>` runs `init` + `plan` from local creds (manually verified
   against at least one real account).

## 11. Follow-ups (parked)

- Add `otelcol-contrib` pin to `scripts/drift_check.py`.
- Gateway-mode Collector config validation.
- Metrics/logs-signal assertions; brownfield E2E; a live-`plan` CI path behind secrets.
