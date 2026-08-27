# Terraform Snapshot Tests

Golden files for generated Terraform modules. CI diffs output against these files.

## Updating snapshots

After running `/otel-backend <vendor>` against `fixtures/nodejs-greenfield`,
copy the generated `main.tf` here:

```bash
cp infra/observability/grafana/main.tf   tests/snapshots/grafana/main.tf.snap
cp infra/observability/datadog/main.tf   tests/snapshots/datadog/main.tf.snap
cp infra/observability/newrelic/main.tf  tests/snapshots/newrelic/main.tf.snap
cp infra/observability/dash0/main.tf     tests/snapshots/dash0/main.tf.snap
```

Commit the updated snapshots with a message like:
`test: update TF snapshots for semconv 1.44.0 / grafana provider 4.x`

## CI check

The CI workflow diffs regenerated output against these golden files.
If output changes unexpectedly, CI fails. Developer reviews the diff and
updates snapshots intentionally.
