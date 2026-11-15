---
description: "Add telemetry inside your own code: a span around one of your functions, or the business metrics you confirmed, so the generated dashboards fill. An in-place edit, shown as a diff first and removable exactly. For Node.js and Python services that /otel-instrument has already set up."
argument-hint: "<file>:<function> | --business [--service <id>] [--span-name <name>] [--line <N>] [--dry-run] [--yes]"
---

# /otel-enrich <file>:<function> | --business [--service <id>] [--span-name <name>] [--line <N>] [--dry-run] [--yes]

`/otel-instrument` never edits code a person wrote: it adds a bootstrap file, and
auto-instrumentation times the requests, outbound calls and database queries it knows about. This
command is the deliberate exception. It does one of two things:

- `/otel-enrich <file>:<function>` puts a span around one function of the user's own, so the time
  spent in it is visible in a trace (Steps 1 to 5).
- `/otel-enrich --business` emits the business metrics the user confirmed in
  `/otel-business-attrs`, at the place in the code that owns each value, so the panels
  `/otel-backend` generated for them have data ("Business metrics" below).

Because it edits hand-written code, three things hold every time:

1. **Nothing silent.** The exact diff is shown and confirmed before anything is written.
2. **Insert-only.** Every edit adds lines between two marker comments and changes no existing
   line, so `/otel-uninstrument --enrichment` removes exactly what was added, months later, with no
   record of what was there before.
3. **Made by code, not by hand.** `scripts/enrich.py` finds the function, writes the edit, and
   refuses unless the result still parses. Never make or adjust these edits with Edit/Write.

The added code calls the plain OpenTelemetry API (no helper file), which does nothing when no SDK
is loaded, so the code keeps working if the bootstrap is ever removed.

Both work in **Node.js (`.js`, `.cjs`, `.mjs`)** and **Python**. Not part of the command yet:
business `dimension` attributes, a business span kind, and database/queue coverage. Say so if
asked, and do not improvise them.

## Flags
- `<file>:<function>`: the file, and the function as `name` or `Class.method`. Required. If the
  user described the function in words instead, find it, then confirm the file and name with them
  before going on.
- `--business`: emit the confirmed business metrics instead (see "Business metrics" below).
- `--service <id>`: the service the file belongs to. Otherwise the service whose `rootDir`
  contains the file.
- `--span-name <name>`: the span's name. Default `<module>.<function>` (see Step 2).
- `--line <N>`: which definition, when the name is defined more than once in the file.
- `--dry-run`: print the diff and stop. Writes nothing; exits non-zero if there is a diff.
- `--yes`: skip the confirmation (for CI or another agent). The diff is still printed.

## Step 1: Load context and check the baseline

Load `.claude/otel-context.json` as `/otel-instrument` Step 1 does (freshness rule from
`/otel-init` Step 1; a stale or absent cache is refreshed as a merge, never a replace). Pick the
service whose `rootDir` contains the file, or `--service`.

The service must already have its bootstrap: look as `/otel-instrument` Step 4 does
(`service.existingOtel.bootstrapFiles`, else the `otel_bootstrap_globs` names under its `rootDir`).
If there is none, stop:

```
<service> has no OpenTelemetry setup yet, so a span added here would go nowhere.
Run /otel-instrument first, then /otel-enrich again.
```

Never generate a bootstrap here.

## Step 2: Name the span

Default: `<module>.<function>`, where `<module>` is the file's base name without its extension
(`lib/orders.js` + `checkout` → `orders.checkout`; for `Class.method`, `<module>.<method>`:
`lib/pricing.js` + `Pricing.total` → `pricing.total`). A span name is a fixed label, never a
value: no ids, no user input, no URL (the `semconv-discipline` rule for span names).

The tracer name is the service's `name` from the context.

## Step 3: Preview the edit

```
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/enrich.py" span --root <repo root> --file <file> \
  --function <function> --span-name <span name> --tracer-name <service name> [--line <N>] --dry-run
```

Show its output unchanged: the unified diff, then any `note:` and `dependency:` lines. Then say
in plain words what the edit does, for someone who has not seen one:

```
This adds a span called "<span name>" around <function>: a timed step that shows up in the trace
of every request that runs it. The lines between the "otel-as-code: enrich" markers are the only
change. If <function> throws, the error is recorded on the span and still thrown to the caller.
```

On `REFUSED:` (exit 2) nothing can be written. Report the reason as given and what the user can
do; the common ones:
- *arrow function with an expression body*, *code on the same line as its brace*: the function has
  to be reshaped first, which is the user's edit to make, not this command's. Offer to enrich the
  function that calls it instead.
- *generator*, *constructor*: a span around it would not measure the work. Suggest the function
  that consumes or calls it.
- *defined N times*: ask which line, then pass `--line`.
- *TypeScript and JSX are not supported yet*: say so. Do not hand-write the wrap.
- *does not parse before the edit*: the file has a syntax error or uses syntax this machine's
  `node`/`python3` can't read. Not something to work around.

If `--dry-run` was passed, stop here, with a non-zero exit when there was a diff.

## Step 4: Confirm, then apply

Unless `--yes`: `Add this span? [y/N]`. On anything but yes, stop; nothing was written.

On yes, run the same command without `--dry-run`. It prints the same diff and `OK: added span`.

If the preview printed a `dependency:` line, the code now imports the OpenTelemetry API package
directly, so it must be a declared dependency. Show the exact command for the project's package
manager (read the lockfile: `npm install @opentelemetry/api`, `pnpm add`, `yarn add`; for Python,
the line to add to the file the note named) and ask before running it. If the user declines, say
that the import works today only because another package happens to bring it in.

## Step 5: Say how to see it, then offer the check

```
✓ Added span "<span name>" around <function> (<file>).

See it: start the service, call the code path that runs <function>, and look at that request's
trace. With the local stack (/otel-local): http://localhost:<G> → Explore → Tempo → Search,
Service Name = <SERVICE_NAME>; the span is nested inside the request.

Remove it any time: /otel-uninstrument --enrichment   (puts the file back exactly)
```

If the local stack is running (its Grafana answers on the port in `otel-local.compose.yaml`), ask:
"Once the service has been restarted and that code path has run, want me to check the span
arrived?" On yes:

```
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/lgtm_check.py" span --grafana http://localhost:<G> \
  --service <SERVICE_NAME> --name "<span name>" --since 900 --wait 30
```

Report its output as-is: what it asked, the span's duration, whether it recorded an error, and
what it is nested under. Exit 1: no such span in the last 15 minutes; the usual causes are the
service not restarted since the edit, the code path not run, or the service not started with
`otel-local.env`. Exit 2: the stack is unreachable. Never say the span arrived unless this check
ran and exited 0.

## Business metrics (`--business`)

`/otel-business-attrs` records what the user confirmed, and `/otel-backend` builds a panel for
each one, but a panel stays empty until the code emits the metric. This mode adds that code, one
metric at a time. Everything above still holds: diff first, insert-only, made by `enrich.py`.

**B1. Load context and check the baseline** as in Step 1 (select the service as `/otel-instrument`
Step 2 does). Then read `businessAttrs` from the cache:
- Take the entries with `"confirmed": true` and `kind` `counter`, `histogram` or `gauge`.
- A `dimension` is not emitted from code: say so in one line per entry and skip it ("a dimension
  is a label on the request metric, which application code cannot add; the span-based backends
  read it from a span attribute instead").
- Run `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/enrich.py" list --root <repo root>`. An entry whose
  id `metric-<name with dashes>` is already listed is emitted already: skip it and say where.
- If nothing is left, say so and stop. If there are no confirmed business attributes at all, point
  at `/otel-business-attrs`; never invent a metric here.

**B2. Find the call site, for each metric.** The entry's `source` says where it was inferred from
(`route POST /checkout`). Read that handler and pick the one line where the business event has
happened:
- a **counter** counts an event: put it where the event is certain (after the order is saved,
  before the `return`), not at the top of the handler, and not on a path that also runs on failure;
- a **histogram** records a value per event (a duration, an amount): the same place, with the
  expression that holds the value;
- a **gauge** records a current level (a queue depth, a ratio): where the level is computed.

For a histogram or gauge you need a `--value` expression that is in scope on that line and is a
number in the metric's unit (`unit: "s"` wants seconds, so `(Date.now() - startedAt) / 1000`, not
milliseconds). If no variable holds the value, do not add one: say what is missing and skip the
metric. This command never changes a line the user wrote.

If you cannot tell where the event happens, ask the user. A metric in the wrong place is worse
than an empty panel: it shows a number that means something else.

**B3. Preview.** For each metric:

```
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/enrich.py" metric --root <repo root> --file <file> \
  --function <function> --at <line> --where <before|after> --name <metric name> \
  --meter-name <service name> [--value "<expression>"] --dry-run
```

The script reads the kind and unit from the cache, and refuses a name that is not a confirmed
entry there. Show its diff unchanged, then one sentence on what it counts or records and when:
"This counts one `com.myorg.checkout.order_placed` each time checkout succeeds; a failed charge
is not counted." On `REFUSED:`, report the reason; for *the middle of a statement*, *closes a
block*, *would never run*, pick another line of the same handler and preview again.

Line numbers move after every edit. Read the file again before previewing the next metric.

**B4. Confirm each one, then apply.** Unless `--yes`: `Add this metric? [y/N]`, per metric. On
yes, run the same command without `--dry-run`. Handle a `dependency:` line as Step 4 does. With
`--dry-run`, preview every metric and stop, with a non-zero exit when any would be added.

**B5. Record the call site.** For each metric applied, set `callSite` on its `businessAttrs`
entry (`{"file": "<file>", "function": "<function>"}`) and write the cache back through
`scripts/write_context.py` with `--existing`, exactly as `/otel-init` Step 4 does. Change nothing
else in the cache.

**B6. Say how to see it.** Metrics are sent on an interval, not per request, so they take a
moment to show:

```
✓ <N> business metric(s) are now emitted: <names>.

See them: restart the service and trigger each event a few times. With the local stack
(/otel-local): http://localhost:<G> → Explore → Prometheus. A metric is stored under its name
with dots as underscores, then its unit, then _total for a counter:
  com.myorg.checkout.order_placed (counter)        → com_myorg_checkout_order_placed_total
  com.myorg.checkout.payment_duration (histogram, s) → com_myorg_checkout_payment_duration_seconds_bucket
If you already ran /otel-backend, the panels it made for these now have data.

Remove them any time: /otel-uninstrument --enrichment
```

If the local stack is running, offer to check one, and on yes run a panel-style query for it:

```
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/lgtm_check.py" query --grafana http://localhost:<G> \
  --expr 'sum(<stored name>{job="<job>"})' --wait 60 --names '<stored name prefix>.*'
```

`<job>` is `<service.namespace>/<service.name>` when the service has a namespace, else
`<service.name>`. Report the output as-is. On exit 1 it lists the metric names Prometheus does
have under that prefix, which usually shows the cause (the event was not triggered yet, or the
service was not restarted). Never say a metric arrived unless this ran and exited 0.

No metric attributes are added in this mode. An attribute on a metric multiplies its series, and a
high-cardinality one (a user id, an order id) is the most expensive mistake in this plugin's
rulebook (`semconv-discipline`, Rule 8); it needs its own confirmation step, which does not exist
yet.

## What the edit looks like

Python: a decorator directly above the `def` (below any decorator already there, so a route
decorator still registers the wrapped function):

```python
# otel-as-code: enrich begin orders-checkout
@_otel_tracer.start_as_current_span("orders.checkout")
# otel-as-code: enrich end orders-checkout
def checkout(cart_id, user_id):
```

Node.js: one block at the top of the function body and one at the end; the body between them is
untouched (a formatter may re-indent it afterwards, which is fine):

```js
async function checkout(cartId, userId) {
  // otel-as-code: enrich begin orders-checkout
  return otelTracer.startActiveSpan('orders.checkout', async (otelSpan) => { try {
  // otel-as-code: enrich end orders-checkout
  ...the function's own lines...
  // otel-as-code: enrich begin orders-checkout
  } catch (otelErr) { otelSpan.recordException(otelErr); otelSpan.setStatus({ code: OtelStatus.ERROR }); throw otelErr; } finally { otelSpan.end(); } });
  // otel-as-code: enrich end orders-checkout
}
```

Each enriched file also gets one `otel-tracer` block near its top (the import and the tracer),
shared by every span in that file and removed with the last one.

A business metric is two blocks with one id: the instrument near the top of the file (after an
`otel-meter` block, shared like the tracer's), and one line at the call site:

```python
# otel-as-code: enrich begin metric-com-myorg-checkout-order-placed
_otel_order_placed = _otel_meter.create_counter("com.myorg.checkout.order_placed", unit="{order}")
# otel-as-code: enrich end metric-com-myorg-checkout-order-placed
...
    order = save(cart)
    # otel-as-code: enrich begin metric-com-myorg-checkout-order-placed
    _otel_order_placed.add(1)
    # otel-as-code: enrich end metric-com-myorg-checkout-order-placed
    return order
```

Two limits to state when they apply:
- A Node.js function that is not `async` but returns a promise: the span ends when the function
  returns, not when the promise settles (the script prints a `note:`).
- In Python, an exception that is part of normal flow (a framework's "400 Bad Request" exception,
  say) is still recorded as an error on the span.
