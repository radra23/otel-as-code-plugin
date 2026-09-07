---
name: deployment-remediation
description: Deployment-config remediation patterns for services /otel-instrument cannot bootstrap (generatorSupported:false, inScope:true — a third-party binary/image with no owned application source, but real native OTel support). Use when generating a deployment-config diff via /otel-remediate.
version: 0.1.0
---

# Deployment-Config Remediation

## Who this is for

`generatorSupported: false, inScope: true` is a real, common category, not an edge case: an
upstream binary or container image (Keycloak, nginx, Envoy, a managed database/queue image, a
Helm-installed operator) with no application source in the repo for `/otel-instrument` to
bootstrap, but a genuine deployed workload with its own native OpenTelemetry (or OTel-adjacent)
configuration surface — usually environment variables or CLI flags read at container start.

`/otel-evaluate`'s `brownfield-auditor` already audits these services well: it reads
`service.deployment.configFiles` (the Kubernetes manifest, Dockerfile, docker-compose file, Helm
values) the same way it does for any other service, and reports missing/misconfigured native OTel
settings as ordinary findings (mostly `CF` — telemetry configuration). What was missing is a way
to turn those findings into a concrete diff, the same way `/otel-instrument --fix <ids>` does for
a `generatorSupported: true` service's source files. This skill is that missing half, dispatched
by `/otel-remediate`.

## v1 scope: Keycloak only

**Only Keycloak is supported in v1.** This list is deliberately a table, not prose, so adding a
second target later is an addition, not a rewrite — but do not guess at an unlisted target's
config surface by analogy; every binary's flags are different, and a wrong guess here writes
config that doesn't do what it claims. For anything not in the table below, `/otel-remediate`
must refuse by name by name, the same "wrong code is worse than no code" principle
`instrumentation-gen` already applies to an unsupported language/runtime — do NOT emit a diff for
a target this skill doesn't cover.

| Target | Detection signal | `inScope` shape |
|---|---|---|
| Keycloak | A container image reference matching `quay.io/keycloak/keycloak`, `keycloak/keycloak`, or the older `jboss/keycloak`, in a Dockerfile `FROM`, a Kubernetes/Helm manifest's `image:` field, or a docker-compose `image:` field | `host: kubernetes` / `container` / `standalone`, `generatorSupported: false` |

## Keycloak: native OTel configuration surface

Keycloak is Quarkus-based; its runtime config properties (kebab-case, e.g. `tracing-enabled`) map
to environment variables by Quarkus's standard convention: uppercase, `-` → `_`, prefixed `KC_`.
Verify current values against Keycloak's own docs before generating
(https://github.com/keycloak/keycloak/blob/main/docs/guides/observability/tracing.adoc,
https://www.keycloak.org/server/logging) — Keycloak's own config surface has already renamed
properties within its lifecycle (see the deprecation note below), so treat this table as
"verified as of this writing," not permanently pinned.

**Tracing** (default OTLP protocol is **gRPC**, default endpoint `http://localhost:4317` — same
default this plugin uses elsewhere, so a target already running a collector on the plugin's
standard port needs no endpoint override):

| Env var | Purpose | Notes |
|---|---|---|
| `KC_TRACING_ENABLED=true` | Turns tracing on. Build-time option (`tracing-enabled`) | Tracing is gated behind the `opentelemetry` feature, which is **enabled by default** in current Keycloak — do not also propose a `--features=opentelemetry` flag unless the target is confirmed on an older version where it wasn't. |
| `KC_TRACING_ENDPOINT` | OTLP traces endpoint | Maps to `quarkus.otel.exporter.otlp.traces.endpoint`. Omit if the deployment already exports elsewhere and only the endpoint is unset — do not invent a value; ask/flag it as `<confirm your collector endpoint>` the same way `instrumentation-gen` never invents a Terraform-owned identifier. |
| `KC_TELEMETRY_SERVICE_NAME` | The `service.name` resource attribute | **Use this, not `KC_TRACING_SERVICE_NAME`** — Keycloak's own docs mark `tracing-service-name` deprecated in favor of `telemetry-service-name`. Default is literally `keycloak`; every Keycloak deployment in a multi-service repo needs this set explicitly or every one of them reports the identical `service.name`. |
| `KC_TELEMETRY_RESOURCE_ATTRIBUTES` | Extra resource attributes (`k8s.namespace.name`, etc.) | Same deprecation as above (was `tracing-resource-attributes`). The Keycloak Operator sets this automatically when present — if the target uses the Operator, do not propose it as missing without checking whether the Operator already injects it. |
| `KC_TRACING_SAMPLER_TYPE` / `KC_TRACING_SAMPLER_RATIO` | Sampler type/ratio | Default sampler `traceidratio`, default ratio `1.0` (all traces sampled) — only propose overriding these if volume is a stated concern; do not propose a sampling change as if it were a gap. |

**Logging** — Keycloak's console handler logs unstructured plain text by default:

| Env var | Purpose | Notes |
|---|---|---|
| `KC_LOG_CONSOLE_OUTPUT=json` | Structured JSON console logs | Also supports `ecs` (Elastic Common Schema) instead of the default JSON shape — propose plain `json` unless the target's existing log pipeline is confirmed ECS-shaped. |

**Metrics** — `KC_METRICS_ENABLED=true` (build-time `metrics-enabled`) is the on/off switch;
if already `true`, that is not a finding — do not propose re-adding it.

## Diff format per manifest type

Propose additions in the syntax of whatever `service.deployment.configFiles` actually contains —
never assume one shape:

- **Kubernetes Deployment/StatefulSet manifest, or Helm values.yaml**: an `env:` list entry per
  variable (`- name: KC_TRACING_ENABLED\n  value: "true"`), inserted into the existing container's
  `env:` block — read the file first to match its existing indentation and quoting style exactly,
  the same "extend, never clobber" discipline `instrumentation-gen` applies to a pre-existing
  `instrumentation.ts`.
- **docker-compose.yml**: an `environment:` map entry (`KC_TRACING_ENABLED: "true"`, or the list
  form `- KC_TRACING_ENABLED=true` — match whichever form the file already uses).
- **Dockerfile**: an `ENV KC_TRACING_ENABLED=true` line, only when the image is built from this
  Dockerfile rather than pulled as-is — a `FROM quay.io/keycloak/keycloak` with no further
  customization has nowhere in the Dockerfile for this to usefully live; say so and point at the
  orchestration manifest instead.

Always show a **unified diff** (`--- a/<path>` / `+++ b/<path>`, `@@` hunk headers) against the
actual file content you read, never a bare "add these lines" list divorced from real context —
the reader needs to see exactly where it goes and what it neighbors.

## What this is not

`/otel-remediate` (v1) **only prints the proposed diff — it never writes.** Unlike a generated
SDK bootstrap file (which this plugin owns and can safely regenerate under `write-guard`), a
Kubernetes Deployment manifest or docker-compose file is infrastructure the plugin does not own
and was not the one to create; write-guard's ownership-marker contract doesn't apply to it, and a
wrong automated edit here has a materially higher blast radius (a live cluster resource) than a
wrong edit to a bootstrap file the plugin generated in the first place. Print-only is not a
missing feature to add later casually — treat "should this write automatically" as its own
deliberate decision, not a default to slide into.
