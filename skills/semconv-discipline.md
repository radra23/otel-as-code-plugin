# OTel Semantic Conventions Discipline

**SEMCONV_VERSION: 1.27.0** — Use stable conventions from this version by default.
Experimental conventions (GenAI, profiling, system) require the `--experimental` flag.

> **Single source of truth.** This `SEMCONV_VERSION` constant is the one place the pinned
> semconv version is defined. Commands and subagents stamp it into generated file headers
> (via the `<SEMCONV_VERSION>` placeholder), and the `semconv-lint` hook reads it back out of
> this file at runtime. Bump it here only — the weekly CI drift job updates this line.

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
- WRONG: `cartId`, `cart_id`, `checkout_cart_id`

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
