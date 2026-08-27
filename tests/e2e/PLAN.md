# E2E Validation Harness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prove the plugin's frozen generated output works end-to-end — SDK bootstrap → Collector → Jaeger with correct `service.*` attrs (#1), `otelcol validate` on the golden Collector config (#3), and a local `terraform plan` helper (#4).

**Architecture:** Validate committed golden artifacts (not live-generated output, which needs the interactive agent). A docker-compose stack wires the *actual* golden Collector config as `app → collector → jaeger`; the same file is validated standalone by `otelcol-contrib validate`. A new `e2e` CI job runs #1 + #3 on push/PR in parallel to the fast jobs; #4 stays local.

**Tech Stack:** bash (`-eo pipefail`), python3 (parsing — repo convention, not jq), Docker Compose, `otelcol-contrib`, Jaeger all-in-one, Node.js + Python OTel SDKs, GitHub Actions.

**Spec:** `tests/e2e/DESIGN.md`

## Global Constraints

- Parse JSON in shell with `python3`, never `jq` (repo convention).
- Reproduce CI shell logic as `bash -eo pipefail` (GitHub Actions default), not zsh.
- Golden bootstrap dependency versions copied **verbatim** from `agents/instrumentation-gen.md`: Node `@opentelemetry/sdk-node@^0.221.0`, `@opentelemetry/sdk-metrics@^2.10.0`, `@opentelemetry/resources@^2.10.0`, `@opentelemetry/exporter-trace-otlp-grpc@^0.221.0`, `@opentelemetry/exporter-metrics-otlp-grpc@^0.221.0`, `@opentelemetry/auto-instrumentations-node@^0.79.0`, `@opentelemetry/semantic-conventions@^1.43.0`; Python `opentelemetry-sdk>=1.44.0`, `opentelemetry-exporter-otlp-proto-grpc>=1.44.0`, `opentelemetry-instrumentation-fastapi>=0.65b0`, `opentelemetry-semantic-conventions>=0.65b0`.
- Golden Collector config mirrors `skills/collector-topology/SKILL.md` (agent mode + cardinality `transform` + required exporter blocks). `memory_limiter` MUST be the first processor in every pipeline.
- Pinned literals (single-source discipline): `OTELCOL_VERSION=0.128.0`, `jaegertracing/all-in-one:1.60`, `node:20-bookworm-slim`, `python:3.12-slim-bookworm`.
- Fixture identities: Node `checkout-api` v`1.4.2`, Python `inventory-api` v`0.3.1`; namespace `storefront`, `deployment.environment.name=e2e` for both.
- New offline tests wire into the `lint-hooks` CI job (per CLAUDE.md); Docker-dependent tests run in the new `e2e` job.
- No Co-Authored-By trailers in commits.

---

### Task 1: Golden agent Collector config + `otelcol validate` (#3)

**Files:**
- Create: `tests/snapshots/collector/otelcol-agent.yaml.snap`
- Create: `tests/collector-validate.sh`

**Interfaces:**
- Produces: `tests/collector-validate.sh` — validates the golden config with a pinned `otelcol-contrib`; exit 0 pass / non-zero fail. Downloads the binary to `${OTELCOL_BIN:-/tmp/otelcol-contrib}` if absent. Reads `OTELCOL_VERSION` (default `0.128.0`).

- [ ] **Step 1: Write the golden agent Collector config**

Create `tests/snapshots/collector/otelcol-agent.yaml.snap`:

```yaml
# Golden agent Collector config — mirrors skills/collector-topology/SKILL.md (agent mode).
# Validated standalone by tests/collector-validate.sh (#3) AND used as the live collector
# in tests/e2e/docker-compose.yml (#1). endpoint is env-driven so the same file serves both.
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
      http:
        endpoint: 0.0.0.0:4318

processors:
  memory_limiter:
    check_interval: 1s
    limit_mib: 256
  transform:
    error_mode: ignore
    trace_statements:
      - context: span
        statements:
          - delete_key(attributes, "user.id")    where IsString(attributes["user.id"])
          - delete_key(attributes, "session.id") where IsString(attributes["session.id"])
          - delete_key(attributes, "request.id") where IsString(attributes["request.id"])
          - delete_key(attributes, "order.id")   where IsString(attributes["order.id"])
  batch:
    timeout: 1s
    send_batch_size: 1024

exporters:
  otlp:
    endpoint: ${env:OTEL_EXPORTER_OTLP_ENDPOINT}
    tls:
      insecure: true   # local agent -> local sink; production terminates TLS (insecure: false)
    timeout: 30s
    retry_on_failure:
      enabled: true
      initial_interval: 5s
      max_interval: 30s
      max_elapsed_time: 300s
    sending_queue:
      enabled: true
      num_consumers: 10
      queue_size: 1000

service:
  pipelines:
    traces:
      receivers: [otlp]
      processors: [memory_limiter, transform, batch]
      exporters: [otlp]
    metrics:
      receivers: [otlp]
      processors: [memory_limiter, batch]
      exporters: [otlp]
    logs:
      receivers: [otlp]
      processors: [memory_limiter, batch]
      exporters: [otlp]
```

- [ ] **Step 2: Write the validation script**

Create `tests/collector-validate.sh`:

```bash
#!/usr/bin/env bash
# tests/collector-validate.sh
# #3: validate the golden agent Collector config with a pinned otelcol-contrib.
# Downloads the binary if absent. Sets a dummy OTLP endpoint so env-substitution of an
# unset var can't produce a false failure.
set -euo pipefail
cd "$(dirname "$0")/.."

OTELCOL_VERSION="${OTELCOL_VERSION:-0.128.0}"
OTELCOL_BIN="${OTELCOL_BIN:-/tmp/otelcol-contrib}"
CONFIG="tests/snapshots/collector/otelcol-agent.yaml.snap"

if [ ! -x "$OTELCOL_BIN" ]; then
  os="$(uname | tr '[:upper:]' '[:lower:]')"
  arch="$(uname -m)"; case "$arch" in x86_64) arch=amd64;; aarch64|arm64) arch=arm64;; esac
  url="https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v${OTELCOL_VERSION}/otelcol-contrib_${OTELCOL_VERSION}_${os}_${arch}.tar.gz"
  echo "Downloading otelcol-contrib ${OTELCOL_VERSION} ($os/$arch)..."
  tmp="$(mktemp -d)"
  curl -fsSL "$url" -o "$tmp/oc.tar.gz"
  tar -xzf "$tmp/oc.tar.gz" -C "$tmp" otelcol-contrib
  mv "$tmp/otelcol-contrib" "$OTELCOL_BIN"; chmod +x "$OTELCOL_BIN"; rm -rf "$tmp"
fi

# Dummy endpoint just so ${env:...} resolves to a non-empty value during validate.
OTEL_EXPORTER_OTLP_ENDPOINT="localhost:4317" "$OTELCOL_BIN" validate --config="$CONFIG"
echo "OK: $CONFIG validates against otelcol-contrib ${OTELCOL_VERSION}"
```

- [ ] **Step 3: Make executable and run — verify it PASSES**

Run:
```bash
chmod +x tests/collector-validate.sh
bash tests/collector-validate.sh
```
Expected: downloads the binary, prints `OK: … validates`. Exit 0.

If validate rejects the `transform`/`trace_statements` syntax, that is a real finding: the `collector-topology` skill template is stale. Modernize BOTH the skill's `transform` block and this golden to the syntax the pinned version accepts (keep them identical — repo convention), then re-run. Do not work around it by pinning an older version.

- [ ] **Step 4: Verify it FAILS on a broken config**

Run:
```bash
sed 's/memory_limiter, transform, batch/transform, memory_limiter, batch/' \
  tests/snapshots/collector/otelcol-agent.yaml.snap > /tmp/bad.yaml
OTEL_EXPORTER_OTLP_ENDPOINT=localhost:4317 /tmp/otelcol-contrib validate --config=/tmp/bad.yaml \
  && echo "UNEXPECTED PASS" || echo "correctly rejected"
```
Expected: `correctly rejected` (memory_limiter-not-first is invalid). Confirms the check has teeth.

- [ ] **Step 5: Commit**

```bash
git add tests/snapshots/collector/otelcol-agent.yaml.snap tests/collector-validate.sh
git commit -m "test(e2e): golden agent Collector config + otelcol validate (#3)"
```

---

### Task 2: Trace assertion + offline unit test (#1 core logic)

**Files:**
- Create: `tests/e2e/assert-traces.sh`
- Create: `tests/e2e/assert-traces.test.sh`
- Create: `tests/e2e/fixtures/jaeger-ok.json`
- Create: `tests/e2e/fixtures/jaeger-missing-version.json`

**Interfaces:**
- Produces: `assert-traces.sh` with two modes:
  - live: `assert-traces.sh --jaeger <url> --service <name> --expect k=v,k=v[,...]` — polls up to `${POLL_TIMEOUT:-30}`s.
  - offline: `assert-traces.sh --traces-json <file> --service <name> --expect k=v,...` — runs the same checks against a saved `/api/traces` response (no network). Used by the unit test.
  - Exit 0 if a trace exists for the service AND every expected `service.*` key/value is present in that service's process tags; else non-zero with a reason.

- [ ] **Step 1: Write the two Jaeger response fixtures**

Create `tests/e2e/fixtures/jaeger-ok.json` (a minimal real-shaped `/api/traces` response):

```json
{
  "data": [
    {
      "traceID": "abc123",
      "spans": [{ "traceID": "abc123", "spanID": "s1", "operationName": "GET /checkout", "processID": "p1" }],
      "processes": {
        "p1": {
          "serviceName": "checkout-api",
          "tags": [
            { "key": "service.name", "type": "string", "value": "checkout-api" },
            { "key": "service.version", "type": "string", "value": "1.4.2" },
            { "key": "service.namespace", "type": "string", "value": "storefront" }
          ]
        }
      }
    }
  ]
}
```

Create `tests/e2e/fixtures/jaeger-missing-version.json` — same as above but with the `service.version` tag object removed from the `tags` array.

- [ ] **Step 2: Write the assertion script**

Create `tests/e2e/assert-traces.sh`:

```bash
#!/usr/bin/env bash
# tests/e2e/assert-traces.sh
# #1 assertion: a trace for --service exists and its resource attrs (Jaeger process tags)
# contain every expected key=value. Live mode polls Jaeger; --traces-json mode reads a saved
# response for offline unit testing. JSON parsed with python3 (repo convention).
set -euo pipefail

JAEGER=""; SERVICE=""; EXPECT=""; TRACES_JSON=""
while [ $# -gt 0 ]; do
  case "$1" in
    --jaeger) JAEGER="$2"; shift 2;;
    --service) SERVICE="$2"; shift 2;;
    --expect) EXPECT="$2"; shift 2;;
    --traces-json) TRACES_JSON="$2"; shift 2;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done
[ -n "$SERVICE" ] && [ -n "$EXPECT" ] || { echo "usage: --service <name> --expect k=v,... (--jaeger <url> | --traces-json <file>)" >&2; exit 2; }

check() {  # stdin: /api/traces JSON. Args: service, expect. Exit 0 ok / 1 mismatch.
  SERVICE="$1" EXPECT="$2" python3 - <<'PY'
import json, os, sys
data = json.load(sys.stdin)
service = os.environ["SERVICE"]
expect = dict(kv.split("=", 1) for kv in os.environ["EXPECT"].split(",") if kv)
traces = data.get("data") or []
if not traces:
    print(f"FAIL: no traces for {service}"); sys.exit(1)
# collect process tags for the target service across the first trace
tags = {}
for proc in (traces[0].get("processes") or {}).values():
    if proc.get("serviceName") == service:
        for t in proc.get("tags") or []:
            tags[t["key"]] = str(t.get("value"))
if not tags:
    print(f"FAIL: no process for service {service}"); sys.exit(1)
for k, v in expect.items():
    if tags.get(k) != v:
        print(f"FAIL: {service} expected {k}={v}, got {tags.get(k)!r}"); sys.exit(1)
print(f"OK: {service} has {', '.join(f'{k}={v}' for k,v in expect.items())}")
PY
}

if [ -n "$TRACES_JSON" ]; then
  check "$SERVICE" "$EXPECT" < "$TRACES_JSON"; exit $?
fi

[ -n "$JAEGER" ] || { echo "live mode needs --jaeger <url>" >&2; exit 2; }
deadline=$(( $(date +%s) + ${POLL_TIMEOUT:-30} ))
while :; do
  if curl -fsS "$JAEGER/api/traces?service=$SERVICE&limit=1" 2>/dev/null | check "$SERVICE" "$EXPECT"; then
    exit 0
  fi
  [ "$(date +%s)" -lt "$deadline" ] || { echo "FAIL: no matching trace for $SERVICE within ${POLL_TIMEOUT:-30}s" >&2; exit 1; }
  sleep 2
done
```

- [ ] **Step 3: Write the failing unit test**

Create `tests/e2e/assert-traces.test.sh`:

```bash
#!/usr/bin/env bash
# tests/e2e/assert-traces.test.sh — offline test of assert-traces.sh parsing logic.
set -uo pipefail
cd "$(dirname "$0")"
pass=0; fail=0
check() { if eval "$2"; then echo "PASS: $1"; pass=$((pass+1)); else echo "FAIL: $1"; fail=$((fail+1)); fi; }

# correct attrs -> exit 0
check "ok fixture passes" \
  'bash assert-traces.sh --traces-json fixtures/jaeger-ok.json --service checkout-api --expect service.name=checkout-api,service.version=1.4.2,service.namespace=storefront >/dev/null'
# missing version -> non-zero
check "missing service.version fails" \
  '! bash assert-traces.sh --traces-json fixtures/jaeger-missing-version.json --service checkout-api --expect service.version=1.4.2 >/dev/null'
# wrong service -> non-zero
check "absent service fails" \
  '! bash assert-traces.sh --traces-json fixtures/jaeger-ok.json --service nope --expect service.name=nope >/dev/null'

echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
```

Run: `bash tests/e2e/assert-traces.test.sh`
Expected (before assert-traces.sh exists / is correct): FAIL.

- [ ] **Step 4: Run test to verify it passes**

Run:
```bash
chmod +x tests/e2e/assert-traces.sh
bash tests/e2e/assert-traces.test.sh
```
Expected: `Results: 3 passed, 0 failed`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add tests/e2e/assert-traces.sh tests/e2e/assert-traces.test.sh tests/e2e/fixtures/
git commit -m "test(e2e): trace-assertion script + offline unit test (#1 logic)"
```

---

### Task 3: Golden SDK bootstraps + instrumented manifests

**Files:**
- Create: `tests/snapshots/instrument/nodejs/tracing.js`
- Create: `tests/snapshots/instrument/nodejs/package.json`
- Create: `tests/snapshots/instrument/python/tracing.py`
- Create: `tests/snapshots/instrument/python/requirements.txt`
- Create: `tests/snapshots/instrument/pins.test.sh`

**Interfaces:**
- Produces: golden bootstraps that read identity from `OTEL_SERVICE_NAME`/`OTEL_SERVICE_VERSION`/`OTEL_SERVICE_NAMESPACE`/`DEPLOYMENT_ENV` and export OTLP to `OTEL_EXPORTER_OTLP_ENDPOINT`. Consumed by `run.sh` (Task 4).

- [ ] **Step 1: Write the Node golden bootstrap** — copy the `tracing.js` template from `agents/instrumentation-gen.md` verbatim, with placeholders resolved to the fixture identity:

Create `tests/snapshots/instrument/nodejs/tracing.js` — the template from `agents/instrumentation-gen.md` lines 48-103, with `<SERVICE_NAME>`→`checkout-api`, `<SERVICE_VERSION>`→`1.4.2`, `<SERVICE_NAMESPACE>`→`storefront`, `<SEMCONV_VERSION>`→`1.44.0`. (Env vars still override these defaults at runtime.)

Create `tests/snapshots/instrument/nodejs/package.json` (fixture app deps + OTel deps from Global Constraints + preload start script):

```json
{
  "name": "checkout-api",
  "version": "1.4.2",
  "private": true,
  "scripts": { "start": "node -r ./tracing.js index.js" },
  "dependencies": {
    "express": "^4.19.2",
    "@opentelemetry/sdk-node": "^0.221.0",
    "@opentelemetry/sdk-metrics": "^2.10.0",
    "@opentelemetry/resources": "^2.10.0",
    "@opentelemetry/exporter-trace-otlp-grpc": "^0.221.0",
    "@opentelemetry/exporter-metrics-otlp-grpc": "^0.221.0",
    "@opentelemetry/auto-instrumentations-node": "^0.79.0",
    "@opentelemetry/semantic-conventions": "^1.43.0"
  }
}
```

- [ ] **Step 2: Write the Python golden bootstrap** — copy the `tracing.py` template from `agents/instrumentation-gen.md` lines 142-198 verbatim, with `<SERVICE_NAME>`→`inventory-api`, `<SERVICE_VERSION>`→`0.3.1`, `<SERVICE_NAMESPACE>`→`storefront`, `<SEMCONV_VERSION>`→`1.44.0`.

Create `tests/snapshots/instrument/python/requirements.txt`:

```text
fastapi>=0.110
uvicorn>=0.29
opentelemetry-sdk>=1.44.0
opentelemetry-exporter-otlp-proto-grpc>=1.44.0
opentelemetry-instrumentation-fastapi>=0.65b0
opentelemetry-semantic-conventions>=0.65b0
```

- [ ] **Step 3: Write the failing pins/syntax test**

Create `tests/snapshots/instrument/pins.test.sh`:

```bash
#!/usr/bin/env bash
# Guards: golden bootstraps stay syntactically valid AND their pins match
# agents/instrumentation-gen.md (the single source for OTel SDK versions).
set -uo pipefail
cd "$(dirname "$0")/../../.."   # repo root
pass=0; fail=0
check() { if eval "$2"; then echo "PASS: $1"; pass=$((pass+1)); else echo "FAIL: $1"; fail=$((fail+1)); fi; }

check "node bootstrap parses" 'node --check tests/snapshots/instrument/nodejs/tracing.js'
check "python bootstrap compiles" 'python3 -m py_compile tests/snapshots/instrument/python/tracing.py'
# every OTel pin in the golden package.json must appear in instrumentation-gen.md
check "node pins match generator" '
  miss=0
  while IFS= read -r line; do
    pkg=$(printf "%s" "$line" | sed -E "s/.*\"(@opentelemetry\/[^\"]+)\".*/\1/")
    grep -qF "\"$pkg\"" agents/instrumentation-gen.md || { echo "  drift: $pkg"; miss=1; }
  done < <(grep -oE "\"@opentelemetry/[^\"]+\": \"[^\"]+\"" tests/snapshots/instrument/nodejs/package.json)
  [ "$miss" -eq 0 ]'

echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
```

Run: `bash tests/snapshots/instrument/pins.test.sh`
Expected before files exist: FAIL.

- [ ] **Step 4: Run to verify it passes**

Run: `bash tests/snapshots/instrument/pins.test.sh`
Expected: `Results: 3 passed, 0 failed`. (Requires `node` and `python3` on PATH.)

- [ ] **Step 5: Commit**

```bash
git add tests/snapshots/instrument/
git commit -m "test(e2e): golden SDK bootstraps + instrumented manifests + pins guard"
```

---

### Task 4: docker-compose stack + orchestrator (#1 integration)

**Files:**
- Create: `tests/e2e/docker-compose.yml`
- Create: `tests/e2e/run.sh`
- Create: `tests/e2e/README.md`

**Interfaces:**
- Consumes: golden Collector config (Task 1), `assert-traces.sh` (Task 2), golden bootstraps + manifests (Task 3), the greenfield fixtures.
- Produces: `run.sh` — seeds throwaway app copies, `compose up`, drives load, asserts both services, always tears down. Exit 0 iff both assertions pass.

- [ ] **Step 1: Write docker-compose.yml**

Create `tests/e2e/docker-compose.yml`:

```yaml
services:
  jaeger:
    image: jaegertracing/all-in-one:1.60
    environment:
      COLLECTOR_OTLP_ENABLED: "true"
    ports:
      - "16686:16686"   # query UI/API (assertions read this from the host)
    healthcheck:
      test: ["CMD", "wget", "-qO-", "http://localhost:16686/"]
      interval: 3s
      timeout: 2s
      retries: 20

  collector:
    image: otel/opentelemetry-collector-contrib:0.128.0
    command: ["--config=/etc/otelcol/config.yaml"]
    environment:
      OTEL_EXPORTER_OTLP_ENDPOINT: "jaeger:4317"   # golden config exports here
    volumes:
      - ../snapshots/collector/otelcol-agent.yaml.snap:/etc/otelcol/config.yaml:ro
    depends_on:
      jaeger:
        condition: service_healthy

  node-app:
    image: node:20-bookworm-slim
    working_dir: /app
    environment:
      OTEL_SERVICE_NAME: "checkout-api"
      OTEL_SERVICE_VERSION: "1.4.2"
      OTEL_SERVICE_NAMESPACE: "storefront"
      DEPLOYMENT_ENV: "e2e"
      OTEL_EXPORTER_OTLP_ENDPOINT: "http://collector:4317"
      PORT: "3000"
    volumes:
      - ./.work/nodejs:/app
    command: ["sh", "-c", "npm install --no-audit --no-fund --loglevel=error && node -r ./tracing.js index.js"]
    depends_on: [collector]

  python-app:
    image: python:3.12-slim-bookworm
    working_dir: /app
    environment:
      OTEL_SERVICE_NAME: "inventory-api"
      OTEL_SERVICE_VERSION: "0.3.1"
      OTEL_SERVICE_NAMESPACE: "storefront"
      DEPLOYMENT_ENV: "e2e"
      OTEL_EXPORTER_OTLP_ENDPOINT: "http://collector:4317"
      OTEL_EXPORTER_OTLP_INSECURE: "true"
    volumes:
      - ./.work/python:/app
    command: ["sh", "-c", "pip install --no-cache-dir -q -r requirements.txt && uvicorn e2e_main:app --host 0.0.0.0 --port 8000"]
    depends_on: [collector]
```

- [ ] **Step 2: Write the orchestrator**

Create `tests/e2e/run.sh`:

```bash
#!/usr/bin/env bash
# tests/e2e/run.sh — bring up the stack, drive load, assert traces for both services, tear down.
set -euo pipefail
cd "$(dirname "$0")"

WORK="./.work"
cleanup() {
  echo "--- collector + app logs (tail) ---"
  docker compose logs --tail=40 collector node-app python-app 2>/dev/null || true
  docker compose down -v --remove-orphans 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

# 1. seed throwaway app copies (fixtures stay pristine)
rm -rf "$WORK"; mkdir -p "$WORK/nodejs" "$WORK/python"
cp -R ../../fixtures/nodejs-greenfield/. "$WORK/nodejs/"
cp ../snapshots/instrument/nodejs/tracing.js "$WORK/nodejs/tracing.js"
cp ../snapshots/instrument/nodejs/package.json "$WORK/nodejs/package.json"   # instrumented manifest
cp -R ../../fixtures/python-greenfield/. "$WORK/python/"
cp ../snapshots/instrument/python/tracing.py "$WORK/python/tracing.py"
cp ../snapshots/instrument/python/requirements.txt "$WORK/python/requirements.txt"
# Python entrypoint: import golden bootstrap (sets providers) then instrument the app.
cat > "$WORK/python/e2e_main.py" <<'PY'
import tracing
from app import app
tracing.instrument_fastapi(app)
PY

# 2. up + wait for jaeger health
docker compose up -d
echo "waiting for stack..."
for _ in $(seq 1 40); do
  curl -fsS "http://localhost:16686/" >/dev/null 2>&1 && break || sleep 3
done

# 3. drive load (retry until apps accept connections, bounded)
drive() { # base_url, then curl commands
  local base="$1"; shift
  for _ in $(seq 1 30); do curl -fsS "$base/health" >/dev/null 2>&1 && break || sleep 2; done
  "$@"
}
drive "http://localhost:3000" bash -c '
  for i in 1 2 3 4 5; do
    curl -fsS http://localhost:3000/health >/dev/null || true
    curl -fsS -XPOST http://localhost:3000/checkout -H "content-type: application/json" -d "{\"cartId\":\"c1\",\"userId\":\"u1\"}" >/dev/null || true
    curl -fsS http://localhost:3000/orders/o1 >/dev/null || true
  done'
# node-app publishes on host 3000? add "3000:3000" to compose if driving from host; otherwise
# exec curl inside the compose network:
docker compose exec -T python-app sh -c 'for i in 1 2 3 4 5; do
  curl -fsS http://localhost:8000/health >/dev/null || true; done' 2>/dev/null || true

# 4. assert (Jaeger reachable on host 16686)
JA="http://localhost:16686"
POLL_TIMEOUT=40 bash assert-traces.sh --jaeger "$JA" --service checkout-api \
  --expect service.name=checkout-api,service.version=1.4.2,service.namespace=storefront
POLL_TIMEOUT=40 bash assert-traces.sh --jaeger "$JA" --service inventory-api \
  --expect service.name=inventory-api,service.version=0.3.1,service.namespace=storefront,deployment.environment.name=e2e

echo "E2E PASS: traces for both services landed with correct service.* attrs"
```

Note for the implementer: the two apps must be reachable for load generation. Simplest is to expose both app ports to the host (`"3000:3000"` on node-app, `"8000:8000"` on python-app) and drive load from the host with `curl`; adjust the compose `ports:` and the `drive` calls to match. Keep whichever approach you pick consistent between compose and `run.sh`, and verify in Step 3.

- [ ] **Step 3: Run the full integration locally — verify PASS and clean teardown**

Run:
```bash
chmod +x tests/e2e/run.sh
bash tests/e2e/run.sh
docker ps -a | grep -E 'node-app|python-app|collector|jaeger' && echo "LEFTOVER CONTAINERS" || echo "clean teardown"
```
Expected: `E2E PASS…`, then `clean teardown`. (First run pulls images + installs deps — several minutes.)

If an assertion fails, read the dumped collector/app logs: common causes are the Python exporter defaulting to TLS (ensure `OTEL_EXPORTER_OTLP_INSECURE=true` and `http://` endpoint), or load firing before the app is ready (widen the `drive` retry bound).

- [ ] **Step 4: Write the README**

Create `tests/e2e/README.md` documenting: what the harness proves (#1/#3/#4), `bash tests/e2e/run.sh` to run #1 locally, `bash tests/collector-validate.sh` for #3, `bash tests/e2e/plan-local.sh <vendor>` for #4, the pinned versions, and that greenfield fixtures stay pristine (throwaway copies under `.work/`, gitignored).

- [ ] **Step 5: Gitignore the work dir and commit**

```bash
echo "tests/e2e/.work/" >> .gitignore
git add tests/e2e/docker-compose.yml tests/e2e/run.sh tests/e2e/README.md .gitignore
git commit -m "test(e2e): docker-compose stack + orchestrator (#1 integration)"
```

---

### Task 5: Local terraform plan helper (#4)

**Files:**
- Create: `tests/e2e/plan-local.sh`
- Create: `tests/e2e/plan-local.test.sh`

**Interfaces:**
- Produces: `plan-local.sh <vendor>` — validates `<vendor>` against `backends.txt`, then runs `terraform init && terraform plan` on that backend's snapshot dir using creds from the environment. Errors cleanly (exit 2) on unknown/missing vendor; not run in CI.

- [ ] **Step 1: Write the script**

Create `tests/e2e/plan-local.sh`:

```bash
#!/usr/bin/env bash
# tests/e2e/plan-local.sh — #4: run `terraform plan` for one backend against your creds.
# Local only (needs real vendor credentials in the environment). Not part of CI.
set -euo pipefail
cd "$(dirname "$0")/../.."

VENDOR="${1:-}"
[ -n "$VENDOR" ] || { echo "usage: plan-local.sh <vendor>   (one of: $(paste -sd'|' backends.txt))" >&2; exit 2; }
grep -qxF "$VENDOR" backends.txt || { echo "unknown vendor '$VENDOR' (see backends.txt)" >&2; exit 2; }

SNAP="tests/snapshots/$VENDOR/main.tf.snap"
[ -f "$SNAP" ] || { echo "no snapshot for $VENDOR at $SNAP" >&2; exit 2; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
cp "$SNAP" "$WORK/main.tf"
echo "Running terraform plan for $VENDOR (credentials must be in your environment)…"
terraform -chdir="$WORK" init -input=false
terraform -chdir="$WORK" plan -input=false
```

- [ ] **Step 2: Write the failing test (arg handling, offline)**

Create `tests/e2e/plan-local.test.sh`:

```bash
#!/usr/bin/env bash
# Offline: verify plan-local.sh rejects bad input without touching terraform.
set -uo pipefail
cd "$(dirname "$0")/../.."
pass=0; fail=0
check() { if eval "$2"; then echo "PASS: $1"; pass=$((pass+1)); else echo "FAIL: $1"; fail=$((fail+1)); fi; }

check "no vendor -> exit 2" '! bash tests/e2e/plan-local.sh >/dev/null 2>&1; [ $? -ne 0 ]'
check "unknown vendor -> exit 2" '! bash tests/e2e/plan-local.sh bogusvendor >/dev/null 2>&1'
check "known vendor is accepted past validation" '
  out=$(bash tests/e2e/plan-local.sh grafana 2>&1 || true)
  # passes vendor validation: reaches the terraform step (init/plan or "terraform: not found"),
  # never the "unknown vendor" branch.
  ! printf "%s" "$out" | grep -q "unknown vendor"'

echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
```

Run: `bash tests/e2e/plan-local.test.sh` — Expected before script exists: FAIL.

- [ ] **Step 3: Make executable, run test to verify pass**

Run:
```bash
chmod +x tests/e2e/plan-local.sh
bash tests/e2e/plan-local.test.sh
```
Expected: `Results: 3 passed, 0 failed`.

- [ ] **Step 4: Commit**

```bash
git add tests/e2e/plan-local.sh tests/e2e/plan-local.test.sh
git commit -m "test(e2e): local terraform plan helper + arg-handling test (#4)"
```

---

### Task 6: CI wiring

**Files:**
- Modify: `.github/workflows/ci.yml` (add `e2e` job; add the two offline tests to `lint-hooks`)

**Interfaces:**
- Consumes: everything above.

- [ ] **Step 1: Add the offline tests to the existing `lint-hooks` job**

In `.github/workflows/ci.yml`, in the `lint-hooks` job's run steps, append (matches how the drift-check offline test is wired):

```yaml
      - name: assert-traces unit test
        run: bash tests/e2e/assert-traces.test.sh
      - name: golden bootstrap pins/syntax test
        run: bash tests/snapshots/instrument/pins.test.sh
      - name: plan-local arg-handling test
        run: bash tests/e2e/plan-local.test.sh
```

- [ ] **Step 2: Add the `e2e` job**

Add a new top-level job under `jobs:` in `.github/workflows/ci.yml`:

```yaml
  e2e:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Collector config validate (#3)
        run: bash tests/collector-validate.sh
        env:
          OTELCOL_VERSION: "0.128.0"
      - name: Trace-flow smoke test (#1)
        run: bash tests/e2e/run.sh
```

(`ubuntu-latest` ships Docker + Docker Compose v2 and `curl`/`python3`; no extra setup needed. The job runs in parallel with the existing jobs because GitHub Actions runs all jobs in a workflow concurrently unless `needs:` is set — do NOT add `needs:`.)

- [ ] **Step 3: Validate the workflow YAML locally**

Run:
```bash
python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/ci.yml')); print('ci.yml: valid YAML')"
```
Expected: `ci.yml: valid YAML`.

- [ ] **Step 4: Commit and push; watch the run**

```bash
git add .github/workflows/ci.yml
git commit -m "ci(e2e): add e2e job (#1 + #3) + wire offline tests into lint-hooks"
git push
```
Then: `gh run list --branch main --limit 1` and `gh run watch` — expected: all jobs, including `e2e`, green.

- [ ] **Step 5: Update the README Status badges/section if desired**

Optional: once `e2e` is green on main, the README Status section can drop "not yet proven end-to-end against … a running Collector" for the Node/Python trace path, since #1 now proves it in CI. Leave the live-backend caveat (#4 is still local-only). Make this edit only after observing a green `e2e` run.

---

## Self-Review

**1. Spec coverage:**
- DESIGN §5 golden artifacts → Tasks 1 (collector) + 3 (bootstraps). ✓
- §6 #1 trace flow → Tasks 2 (assertion) + 4 (stack/orchestrator). ✓
- §7 #3 collector validate → Task 1. ✓
- §8 #4 local plan → Task 5. ✓
- §9 CI + error handling (trap teardown, bounded timeouts, log dumps) → Task 4 (run.sh trap/logs/timeouts) + Task 6 (job). ✓
- §9 pins → Global Constraints + Tasks 1/3/4. ✓
- §10 acceptance criteria 1-5 → Tasks 1,4,6,4,5 respectively. ✓

**2. Placeholder scan:** No TBD/TODO. Every code step has real content. The one implementer decision (host-port vs in-network load generation, Task 4 Step 2 note) is spelled out with both options and a "keep consistent + verify" instruction — a genuine environment choice, not a hidden gap.

**3. Type/name consistency:** `assert-traces.sh` flags (`--jaeger/--service/--expect/--traces-json`) match between Task 2 (definition), its test, and Task 4 (`run.sh` calls). `OTELCOL_VERSION`/`OTELCOL_BIN` consistent across Task 1 and Task 6. Golden paths (`tests/snapshots/collector/…`, `tests/snapshots/instrument/{nodejs,python}/…`) consistent across Tasks 1/3/4. `backends.txt` used for vendor validation (Task 5) per repo convention. Pins identical to `agents/instrumentation-gen.md`.
