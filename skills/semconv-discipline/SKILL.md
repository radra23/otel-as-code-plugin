---
name: semconv-discipline
description: OpenTelemetry semantic-convention rules — resource vs span attributes, HTTP/DB/messaging attribute names, deprecations, custom-namespace prefixing, and cardinality limits. Use when writing, generating, or reviewing OTel instrumentation code.
version: 0.1.0
---

# OTel Semantic Conventions Discipline

**SEMCONV_VERSION: 1.44.0** — Use stable conventions from this version by default.
Experimental conventions (GenAI, profiling, system) require the `--experimental` flag.

> **Single source of truth.** This `SEMCONV_VERSION` constant is the one place the pinned
> semconv version is defined. Commands and subagents stamp it into generated file headers
> (via the `<SEMCONV_VERSION>` placeholder), and the `semconv-lint` hook reads it back out of
> this file at runtime. Bump it here only — the weekly CI drift job updates this line.
>
> **It is the specification version, not a package version.** The SDK packages carry their own,
> independent numbering — `@opentelemetry/semantic-conventions` and
> `opentelemetry-semantic-conventions` each release on their own cadence and will not equal
> this number. Never treat the two as the same, and never derive one from the other.
>
> Which constants a package exports, and from which entry point, is a **property of the
> installed package, not of this version**. Check it rather than asserting it:
>
> ```
> node -e "const s=require('@opentelemetry/semantic-conventions'); console.log(s.ATTR_SERVICE_NAMESPACE)"
> python -c "from opentelemetry.semconv.resource import ResourceAttributes as R; print(getattr(R,'DEPLOYMENT_ENVIRONMENT_NAME','<absent>'))"
> ```
>
> A generated comment claiming an attribute "is incubating", "is not on the root export", or
> "was already stable at <version>" is a claim about a package release. It ages into a confident
> falsehood the moment the dependency moves, and it costs a verification pass to catch. If a
> workaround is genuinely needed, state what was observed and at what package version; if
> nothing needs explaining, write nothing.

## Resource vs Span Attributes

Resource attributes describe the **entity producing telemetry** — they are set once on
the `Resource` object and appear on every span/metric/log from that process.
Span attributes describe a **single operation**.

**Resource attributes (NEVER set on spans):**
- `service.name` — name of the service
- `service.version` — version string
- `service.namespace` — logical grouping
- `service.instance.id` — unique instance identifier
- `deployment.environment.name` — e.g. `production`, `staging`
- `host.name`, `host.id`
- `container.id`, `k8s.pod.name`

**Common violation:** `span.setAttribute('service.name', ...)` — this is WRONG.
`service.name` must be on the Resource, not on spans.

## HTTP Conventions (semconv 1.23+)

Use the NEW names (1.23+ stable):
| OLD (deprecated)    | NEW (use this)            |
|---------------------|---------------------------|
| `http.method`       | `http.request.method`     |
| `http.url`          | `url.full`                |
| `http.status_code`  | `http.response.status_code` |
| `http.host`         | `server.address`          |
| `http.scheme`       | `url.scheme`              |
| `http.target`       | `url.path` + `url.query`  |

## Database Conventions

Use the NEW names (the four below are stable root exports of `@opentelemetry/semantic-conventions`;
the OLD names are incubating/deprecated):

| OLD (deprecated)   | NEW (use this)        |
|--------------------|-----------------------|
| `db.system`        | `db.system.name`      |
| `db.statement`     | `db.query.text`       |
| `db.operation`     | `db.operation.name`   |
| `db.name`          | `db.namespace`        |

- `db.system.name` — REQUIRED (e.g. `postgresql`, `redis`, `mongodb`). NOT `db.system`, which is
  deprecated (replaced by `db.system.name`) — this was the one entry the list had left on the old
  name while the other three were already modernised.
- `db.namespace` — database name
- `db.operation.name` — e.g. `SELECT`, `INSERT`
- `db.query.text` — sanitized query (no PII)

## Messaging Conventions

- `messaging.system` — REQUIRED (e.g. `kafka`, `rabbitmq`, `aws_sqs`)
- `messaging.destination.name` — topic or queue name
- `messaging.operation.type` — `publish`, `receive`, `process`

⚠ **Every `messaging.*` attribute is incubating** — exported ONLY from the package's
`./incubating` entry point, not the stable root. A TypeScript/CommonJS project on
`moduleResolution: "node"` (the legacy default) cannot resolve that subpath at all, so generated
code that imports these from the root fails to compile. See the "Incubating semconv attributes and
the `/incubating` subpath" section in `agents/instrumentation-gen.md` for how to handle it (bump
`moduleResolution`, or use the verified string literal). This is a stability property of the
package, so verify against the installed version rather than asserting.

## General / connection attributes (deprecations)

| OLD (deprecated)  | NEW (use this)                                                        |
|-------------------|-----------------------------------------------------------------------|
| `peer.service`    | `server.address` (+ `server.port`) on the CLIENT span; identity comes from the callee's own `service.name` resource attribute |

## Custom / Business Attribute Namespace Rule

Custom attributes MUST use a reverse-DNS namespace prefix:
- CORRECT: `com.myorg.checkout.cart_id`
- WRONG: `cartId`, `cart_id`, `checkout_cart_id`, `biz.checkout.cart_id`

**Two distinct problems, two severities — do not collapse them into one "no prefix" finding:**

1. **Reserved-namespace collision — ERROR, rename is not optional.** The attribute's first
   segment is a namespace OpenTelemetry reserves, so a backend that knows the reserved meaning
   can silently reinterpret it, and the collision worsens as the registry grows. Reserved root
   namespaces (non-exhaustive, but check the name's first segment against it):
   `service.`, `deployment.`, `telemetry.`, `otel.`, `host.`, `container.`, `k8s.`, `process.`,
   `cloud.`, `faas.`, `http.`, `url.`, `server.`, `client.`, `network.`, `dns.`, `db.`, `rpc.`,
   `messaging.`, `message.`, `user.`, `session.`, `error.`, `exception.`, `code.`, `gen_ai.`,
   `feature_flag.`, `peer.`. Example collisions: `deployment.name` (inside `deployment.*`),
   `message.notificationId` (inside the RPC `message.*` registry). Fix = rename out of the
   reserved namespace.
2. **Merely unprefixed — WARNING, fix at the team's convenience.** A single-segment or camelCase
   house attribute in a namespace OTel does not claim (`app.name`, `vm.id`, `action.type`).
   Nothing breaks; prefix it `com.<org>.*` when convenient.

This applies to business attributes too. `biz.*` appears in `business-attr-ux` only as a
pre-namespace **placeholder shape** for inferred candidates; it is never a name that gets
written. Candidates are presented already namespaced once the namespace is known, so the string
the user approves is the conformant one — see "Business Attributes — Always Confirm" there.

Infer the namespace from:
1. npm scope: `@myorg/service` → `com.myorg`
2. Maven groupId: `com.example.service` → `com.example`
3. Python package: `myorg.inventory` → `com.myorg` (ask if ambiguous)

## Span Kind Rules

| Kind      | When to use                                      | Required attributes          |
|-----------|--------------------------------------------------|------------------------------|
| `SERVER`  | Incoming HTTP/RPC                                | `server.address`, `url.path` |
| `CLIENT`  | Outgoing HTTP/RPC/DB call                        | `server.address`, `server.port` |
| `PRODUCER`| Publishing to a message queue                    | `messaging.system`, `messaging.destination.name` |
| `CONSUMER`| Receiving from a message queue                   | `messaging.system`, `messaging.operation.type` |
| `INTERNAL`| Internal operations (default if unsure)          | none required                |

## Cardinality Warnings

A high-cardinality (unbounded) identifier's harm depends on WHERE it lands — and the worst
position is the one the old one-line rule never mentioned. Tier findings by position:

| Position | Severity | Why |
|----------|----------|-----|
| **Metric dimension** (a counter/histogram tag/label) | **error** | one permanently-retained time series per distinct value; sampling does not touch it; cost is unbounded and the series persist in the backend even after the code is fixed |
| **Span attribute** | warning | ingest + index cost only; bounded by sampling; ages out with span retention |
| **Span event attribute / log record** | acceptable | the prescribed home for a per-request identifier |

So the fix differs by position: for a **metric dimension** it is "remove the tag" (irreversible
damage otherwise); for a **span attribute** it is "consider moving to a span event or log". Note
the Collector `transform` `delete_key` guardrail operates on **spans only** — it cannot clean up
an identifier that already reached a metric dimension, so that case must be caught in code.

The one-line form, kept because it is still true for the common case: high-cardinality
identifiers do not belong as span attributes — use events or logs instead — but a metric
dimension is worse, not exempt.

**Canonical high-cardinality identifiers** — the same set is enforced by the `semconv-lint`
hook (at the source level, matching `userId` / `user_id` spellings) and by the Collector
`transform` drop-list in `collector-topology` (at the span-attribute level, matching the
dotted `user.id` form). Keep these two lists in sync when adding an identifier:
`user.id`, `session.id`, `request.id`, `order.id`.

Also flag, and route to span events or structured logs:
- Raw SQL query strings → must be sanitized before use as `db.query.text`
- File paths with user data
- Full URLs with query parameters containing PII

Signal: if an attribute value could have >10,000 distinct values in production, flag it.
