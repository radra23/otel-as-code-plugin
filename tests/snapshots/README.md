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

`tests/snapshots/grafana-selfhosted/main.tf.snap` (from `/otel-backend grafana --self-hosted`,
#167) is the one exception: it is NOT a `backends.txt` vendor — `grafana` covers both flavors —
so the `validate-terraform` job's `backends.txt`-driven loop above never touches it. It has its
own dedicated CI step instead; update it by hand the same way if the self-hosted generation
shape changes.

Commit the updated snapshots with a message like:
`test: update TF snapshots for semconv 1.44.0 / grafana provider 4.x`

## CI check

The CI `validate-terraform` job downloads each backend's real provider and runs
`terraform validate` on every snapshot — they are self-contained (inline `variable` blocks) so
each validates standalone. This catches provider-schema breaks, **not** content drift: CI does not
regenerate and diff. When you intentionally change generation, update the snapshots by hand (see
above) and review the diff yourself. (`tests/check-snapshots.sh` is a local helper for that manual
regenerate-and-compare — it is not run by CI.)

## Local stack (`/otel-local`)

`tests/snapshots/local-stack/` holds the golden `otel-local.compose.yaml` and `otel-local.env`
that `/otel-local` writes for `fixtures/nodejs-greenfield` (its app listens on 3000, so Grafana is
remapped to host 3001). `tests/check-snapshots.sh` diffs a fresh run against them, and the
`local-stack-e2e` CI job starts the stack from the golden compose file and asserts a trace comes
back through Grafana's datasource proxy (`tests/e2e/local-stack.sh`). The image tag must match
`commands/otel-local.md`; `tests/drift-check.test.sh` fails if the two disagree.
