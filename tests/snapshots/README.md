# Terraform Snapshot Tests

Golden files for generated Terraform modules. CI runs `terraform validate` on each (they are
self-contained), catching provider-schema breaks — see the `validate-terraform` job in the CI
workflow. CI does NOT diff regenerated output against these files.

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

The CI `validate-terraform` job downloads each backend's real provider and runs
`terraform validate` on every snapshot — they are self-contained (inline `variable` blocks) so
each validates standalone. This catches provider-schema breaks, **not** content drift: CI does not
regenerate and diff. When you intentionally change generation, update the snapshots by hand (see
above) and review the diff yourself. (`tests/check-snapshots.sh` is a local helper for that manual
regenerate-and-compare — it is not run by CI.)
