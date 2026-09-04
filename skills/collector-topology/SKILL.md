---
name: collector-topology
description: OpenTelemetry Collector pipeline topology (agent / gateway modes), tail-sampling, and cardinality-guardrail patterns. Use when generating an otelcol-contrib config.
version: 0.1.0
---

# OpenTelemetry Collector Topology

## Two modes: agent and gateway

### Agent mode
Runs on every host/pod alongside the application. Receives OTLP from the app,
applies basic processing, forwards to a gateway or directly to a backend.

```yaml
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317      # app sends here
      http:
        endpoint: 0.0.0.0:4318

processors:
  batch:
    timeout: 1s
    send_batch_size: 1024
  memory_limiter:
    check_interval: 1s
    limit_mib: 256

exporters:
  otlp:
    endpoint: gateway.internal:4317  # or backend endpoint
    tls:
      insecure: false

service:
  pipelines:
    traces:
      receivers: [otlp]
      processors: [memory_limiter, batch]
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

### Gateway mode
Centralized aggregation tier. Receives from agents, applies tail sampling, exports to backend(s).

Adds `tail_sampling` processor between `memory_limiter` and `batch`:

```yaml
processors:
  tail_sampling:
    decision_wait: 10s
    num_traces: 100000
    expected_new_traces_per_sec: 10000
    policies:
      - name: errors-policy
        type: status_code
        status_code: {status_codes: [ERROR]}
      - name: slow-traces-policy
        type: latency
        latency: {threshold_ms: 1000}
      - name: debug-policy
        type: string_attribute
        string_attribute:
          key: debug.sampling
          values: ["true"]
      - name: probabilistic-fallback
        type: probabilistic
        probabilistic: {sampling_percentage: 10}
```

Wire tail sampling into the traces pipeline only (metrics and logs use direct forwarding):

```yaml
service:
  pipelines:
    traces:
      receivers: [otlp]
      processors: [memory_limiter, tail_sampling, batch]
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

## Receiver auth (`--public` — internet-exposed collectors)

The `receivers.otlp` block above binds `0.0.0.0` with **no auth** — fine when the collector is
only reachable from localhost or a shared private network, a real gap when it isn't. That happens
for a deployment shape neither mode's base template assumes: the app runs on a platform with no
private-networking path to a collector it doesn't share a host with (e.g. a serverless-container
platform that can't run a sidecar, so the collector runs on a separate, internet-reachable host).
An unauthenticated receiver there lets anyone who finds the endpoint (trivial — DNS + a standard
OTLP port) push arbitrary telemetry through it on the owner's ingest quota, or worse (#107,
confirmed in a real deployment: Scaleway Serverless Containers with a collector on a separate
Instance, no shared private network).

This is opt-in via `--public`, never a default: most agent/gateway deployments genuinely are
same-host or private-network, and forcing auth on every user would be disruptive for no benefit in
the common case. `bearertokenauth` (`open-telemetry/opentelemetry-collector-contrib`) is currently
**beta stability** — functionally solid and confirmed working server-side on a receiver (not just
client-side on an exporter — verify this against the extension's own README/source if the pin
moves, since summaries of it are inconsistent on this point), but note the beta status when
recommending it, consistent with how `language-maturity` flags below-Stable components elsewhere
in this plugin. When `--public` is set, add the extension and wire it into **both** receiver
protocols:

```yaml
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
        auth:
          authenticator: bearertokenauth
      http:
        endpoint: 0.0.0.0:4318
        auth:
          authenticator: bearertokenauth

extensions:
  bearertokenauth:
    token: "${env:COLLECTOR_AUTH_TOKEN}"   # NEVER a literal token in the file

service:
  extensions: [bearertokenauth]
  pipelines: {}   # unchanged — pipelines don't reference extensions directly
```

A client must then send `Authorization: Bearer <token>` (the extension's default scheme/header) or
the request is rejected before it reaches any pipeline. **TLS in front of the collector is a
requirement here, not an optional extra** (a reverse proxy such as Caddy, or the OTLP receiver's
own `tls:` block): this bearer token is a shared secret sent on every request, and without
transport encryption it travels in cleartext across the public internet — anyone who can observe
the network path recovers it and defeats the whole point of adding auth to an internet-exposed
receiver. Neither `--public`'s generated config nor this skill sets TLS itself (deployment-specific
— certs, a proxy, or the receiver's native `tls:` block are all valid, so the plugin does not pick
one), so state this as a REQUIRED step in the next-steps output, not a passing mention. Print in
the next-steps output that the user must (1) terminate TLS in front of this collector, (2) generate
a random token and set it as `COLLECTOR_AUTH_TOKEN` on the collector's host, and (3) configure
every sending app with `OTEL_EXPORTER_OTLP_HEADERS=Authorization=Bearer <same token>`.

`--public`'s **receiver** wiring applies identically to agent and gateway mode — both share this
`receivers.otlp` block. The **sender-side** instructions do NOT transfer, though: agent mode's
senders are apps (SDKs), configured via the `OTEL_EXPORTER_OTLP_HEADERS` env var; gateway mode's
senders are agent Collectors, which need **client-side** `bearertokenauth` wired into their own
`exporters.otlp.auth.authenticator` instead — an otelcol exporter does not read
`OTEL_EXPORTER_OTLP_HEADERS`. Printing the app-side instruction for a gateway-mode collector
produces guidance the user cannot act on; see `/otel-collector`'s Step 6 for the per-mode text.

**Also set the exporter's `tls.insecure: false` when `--public` is set.** This is a separate leg
from everything above — the receiver-auth work is entirely about the *inbound* hop (sender →
this collector); this is about the collector's *own outbound* hop (this collector → its
backend/gateway) — but the two correlate: the base agent template defaults `tls.insecure: true`
on the exporter because it assumes a local-dev shape ("local agent → local sink"), and a
`--public` collector is by definition not that shape — it exists because the deployment has a
real network between hosts, so its outbound leg should not default to a local-loopback
assumption either. This is a judgment call tied to the flag, not a hard technical requirement of
`bearertokenauth` itself, so state it as generation guidance here (not folded into the receiver
auth explanation above) rather than leaving it as an unexplained value only the golden shows.

## Cardinality Guardrails (add to agent config)

Always include a `transform` processor to drop high-cardinality span attributes
that are common mistakes:

```yaml
processors:
  transform:
    error_mode: ignore
    trace_statements:
      - context: span
        statements:
          # Drop the canonical high-cardinality identifiers (kept in sync with the
          # semconv-discipline skill and the semconv-lint hook).
          # OTTL uses `where` (not `if`) as the statement-level conditional keyword.
          - delete_key(attributes, "user.id")           where IsString(attributes["user.id"])
          - delete_key(attributes, "session.id")        where IsString(attributes["session.id"])
          - delete_key(attributes, "request.id")        where IsString(attributes["request.id"])
          - delete_key(attributes, "order.id")          where IsString(attributes["order.id"])
```

When generating config, check the context JSON for any attributes marked high-cardinality
by the `brownfield-auditor` and add matching `delete_key` statements.

## Required exporter configuration

Always include:
1. `retry_on_failure` block on all exporters
2. `sending_queue` with in-memory queue (no `storage` extension — file-backed queue is v1)
3. `timeout: 30s` on exporters

```yaml
exporters:
  otlp:
    endpoint: ${env:OTEL_EXPORTER_OTLP_ENDPOINT}
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
```

## otelcol-contrib vs otelcol

Always generate configs for `otelcol-contrib` (the distribution with all receivers,
processors, and exporters). The base `otelcol` distribution lacks several processors
used in these templates (e.g. `tail_sampling`, `transform`).

Validate command: `otelcol-contrib validate --config=<file>`

## Processor ordering rule

`memory_limiter` MUST always be the first processor in every pipeline.
This is a hard OTel Collector constraint — placing it after other processors
means those processors run before the memory check and can cause OOM crashes.

Correct order: `[memory_limiter, (optional: transform, tail_sampling), batch]`
