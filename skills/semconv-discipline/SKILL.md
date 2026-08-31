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

- `db.system` — REQUIRED (e.g. `postgresql`, `redis`, `mongodb`)
- `db.namespace` — database name
- `db.operation.name` — e.g. `SELECT`, `INSERT`
- `db.query.text` — sanitized query (no PII)
- NOT `db.statement` (deprecated)

## Messaging Conventions

- `messaging.system` — REQUIRED (e.g. `kafka`, `rabbitmq`, `aws_sqs`)
- `messaging.destination.name` — topic or queue name
- `messaging.operation.type` — `publish`, `receive`, `process`

## Custom / Business Attribute Namespace Rule

Custom attributes MUST use a reverse-DNS namespace prefix:
- CORRECT: `com.myorg.checkout.cart_id`
- WRONG: `cartId`, `cart_id`, `checkout_cart_id`, `biz.checkout.cart_id`

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

High-cardinality attributes MUST NOT be span attributes — use events or logs instead.

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
