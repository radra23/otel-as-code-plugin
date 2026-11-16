---
description: "Generate a test that fails when a service's telemetry goes missing: it sends one request through the service and asserts the request's span, the spans /otel-enrich added and the confirmed business metrics all came out. No backend, nothing leaves the machine. For Node.js and Python services that /otel-instrument has already set up."
argument-hint: "[--service <id>] [--route \"<METHOD> <path>\"] [--dry-run] [--force]"
---

# /otel-test [--service <id>] [--route "<METHOD> <path>"] [--dry-run] [--force]

Instrumentation breaks silently. A refactor renames a handler, drops a middleware or loses the
bootstrap flag from the start command, and no test fails: the dashboards and alerts just go quiet.
This command writes one test into the service that fails instead, and names what is missing.

The test sends **one real request** through the service and asserts three things came out:
- the request's own span (the server span auto-instrumentation makes),
- every span `/otel-enrich` added on that code path, inside the request's trace,
- every confirmed business metric `/otel-enrich --business` emits on that path.

It needs no backend and sends nothing off the machine:
- **Node.js** (`otel.test.cjs`, `node:test`, no new dependency): starts the service the way
  production does, on a free port, with the exporter pointed at a small receiver inside the test.
- **Python** (`test_otel.py`, `unittest`, which pytest also runs): calls the ASGI or WSGI app in
  the test process, with the SDK's in-memory exporter in place of the real one.

The file is rendered by `scripts/telemetry_test.py` from a small spec. Never write or adjust the
test with Write/Edit: build the spec, and let the script write the file.

Other languages are not supported yet. Say so if asked, and do not hand-write a test for them.

## Flags
- `--service <id>`: the service to test. Otherwise selected as `/otel-instrument` Step 2 does.
- `--route "<METHOD> <path>"`: the request to send (`"POST /checkout"`). Otherwise chosen in Step 2.
- `--dry-run`: print the test as a diff and stop. Writes nothing; exits non-zero if there is a diff.
- `--force`: regenerate a test this command wrote earlier. A file of the same name that this
  plugin did not generate is never overwritten, with or without `--force`.

## Step 1: Load context and check the baseline

Load `.claude/otel-context.json` as `/otel-instrument` Step 1 does (freshness rule from
`/otel-init` Step 1; a stale or absent cache is refreshed as a merge, never a replace), and select
the service.

- Its `language` must be `nodejs` or `python`, and its `runtime` must not be `browser`. Otherwise
  stop: "/otel-test supports Node.js and Python services today."
- It must already have its bootstrap (`service.existingOtel.bootstrapFiles`, else the
  `otel_bootstrap_globs` names under its `rootDir`). If not, stop and point at `/otel-instrument`:
  there is no telemetry to protect yet.

## Step 2: Decide what the test expects

**What exists to assert.** Run:

```
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/enrich.py" list --root <repo root>
```

- Each id under the service's `rootDir` that is not `otel-tracer`, `otel-meter`, `metric-*` or
  `client-*` is a span `/otel-enrich` added. Its span name is in the block: read it from the file
  (`startActiveSpan('<name>'`, `start_as_current_span("<name>"`), never guess it from the id.
- Each `metric-*` id is a business metric; its name is in the `create_counter(...)` /
  `createCounter(...)` line of the block.

A service with no enrichment still gets a test: it asserts the request's own span.

**Which request.** With `--route`, use it. Otherwise read the route handlers and pick the one
request that reaches the most of those spans and metrics. Prefer one that can run with nothing else
started: this test starts the service alone, with no database, queue or other service beside it.
If every candidate needs one, say so and ask the user which route to use and how its dependencies
are provided in their tests; do not invent a fake.

Work out, by reading the code:
- the method, the path with real values in place of parameters (`/items/1`), a JSON body the
  handler accepts, and the status it answers with;
- which spans and metrics that request reaches. One the request does not reach goes in
  `notCovered` with a short reason ("only runs on the refund path"). Never list a span as expected
  that the request cannot reach, and never drop one silently.

**The request span's name** is `<METHOD> <route template>`, written the way the framework writes
the route: `POST /checkout`, `GET /items/:id` (Express), `GET /items/{item_id}` (FastAPI),
`GET /items/<int:item_id>` (Flask). If you are not sure, Step 4 tells you: the failure lists the
spans that did arrive.

**How the service starts.**
- Node.js: `start` is the argument list node runs it with (`["-r", "./tracing.js", "index.js"]`).
  When `package.json` has a script that is exactly that command (`"start": "node -r ./tracing.js
  index.js"`), also set `startScript` to its name: the test then reads the script on every run, so
  a start command that loses its bootstrap flag fails the test. `portEnv` is the variable the
  service reads its port from (default `PORT`); if the port is hard-coded, say that the test
  cannot pick a free port and stop.
- Python: `app` is the object the server runs, as `module:attribute` (`main:app`, what follows
  `uvicorn` or `gunicorn` in the start command), and `interface` is `asgi` (FastAPI, Starlette) or
  `wsgi` (Flask, Django's WSGI app). `bootstrap` is the generated bootstrap's module name
  (`tracing`): the test then fails if importing the app no longer imports it.

## Step 3: Preview, confirm, write

Write the spec to a temporary file (not into the repo) and preview:

```
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/telemetry_test.py" render --root <repo root> --spec <spec file> --dry-run
```

The spec's fields are documented at the top of that script. Show the user, in plain words, what
the test will do before showing the file:

```
This test sends POST /checkout to <service> and fails unless these came out:
  - the request's span:  POST /checkout
  - spans:               orders.checkout, orders.loadLines, pricing.total
  - metrics:             com.myorg.checkout.order_placed
Not covered (this request does not reach them):
  - orders.refund: only runs on the refund path
```

On `REFUSED:` nothing was written; report the reason as given. *exists and was not generated by
otel-as-code* means the user has their own file of that name: leave it, and ask them to rename it
if they want this test. *pass --force* means an earlier generated test is there: re-run with
`--force` only if the user asked for a regeneration.

If `--dry-run` was passed, stop here, with a non-zero exit when there was a diff. Otherwise run
the same command without `--dry-run` (add `--force` only when the user passed it).

## Step 4: Run it, and only hand over a test that passes

Run the test from the service's directory:

```
node --test otel.test.cjs                 # Node.js
python -m unittest test_otel              # Python, with the project's interpreter or virtualenv
```

- **It passes:** go to Step 5.
- **It fails on the request's span name**, and the spans that arrived include the right one under
  a different spelling: fix `serverSpan` in the spec and render again with `--force`.
- **It fails because a span or metric you expected is missing:** read the code path again. If the
  request does not reach it, move it to `notCovered` with the reason. If it should reach it and
  does not, that is a real finding: the telemetry is already broken. Report it and stop; do not
  delete the expectation to get a green test.
- **The service does not start, or the request does not answer as expected:** the request needs
  something this test does not provide. Tell the user what, and ask how to proceed.

Never hand over a test that you have not seen pass, and never say it passes unless this run
exited 0.

## Step 5: Say what it protects and how to run it

```
✓ Wrote <path>. It passes.

It sends <METHOD> <path> through <service> and fails if any of these stops coming out:
  <the request's span, the spans, the metrics>
Not covered: <notCovered, or "nothing: every enriched span and business metric is asserted">

Run it:    <the command from Step 4>
In CI:     add that command to the job that runs your tests.
Remove it: /otel-uninstrument removes it with the bootstrap.
```

Say these when they apply:
- Node.js, a project that runs its tests with Jest or Vitest: `otel.test.cjs` uses Node's built-in
  runner, so run it with `node --test` beside the project's own runner. Jest's default pattern does
  not pick up `.cjs`; a Vitest project should exclude the file.
- Python: the test must run in its own process (`python -m unittest test_otel`), because
  OpenTelemetry can be set up only once per process. In a pytest run where another test imported
  the app first, it fails with a message that says so.
- After `/otel-enrich` adds or removes telemetry, re-run `/otel-test --force` so the test follows.
