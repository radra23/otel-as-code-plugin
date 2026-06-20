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
