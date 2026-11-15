---
description: "Add a span around one of your own functions, so it shows up in traces: an in-place edit to your code, shown as a diff first and removable exactly. For Node.js and Python services that /otel-instrument has already set up."
argument-hint: "<file>:<function> [--service <id>] [--span-name <name>] [--line <N>] [--dry-run] [--yes]"
---

# /otel-enrich <file>:<function> [--service <id>] [--span-name <name>] [--line <N>] [--dry-run] [--yes]

`/otel-instrument` never edits code a person wrote: it adds a bootstrap file, and
auto-instrumentation times the requests, outbound calls and database queries it knows about. This
command is the deliberate exception. It puts a span around one function of the user's own, so the
time spent in it is visible in a trace.

Because it edits hand-written code, three things hold every time:

1. **Nothing silent.** The exact diff is shown and confirmed before anything is written.
2. **Insert-only.** Every edit adds lines between two marker comments and changes no existing
   line, so `/otel-uninstrument --enrichment` removes exactly what was added, months later, with no
   record of what was there before.
3. **Made by code, not by hand.** `scripts/enrich.py` finds the function, writes the edit, and
   refuses unless the result still parses. Never make or adjust these edits with Edit/Write.

The added code calls the plain OpenTelemetry API (no helper file), which does nothing when no SDK
is loaded, so the code keeps working if the bootstrap is ever removed.

This is the first slice of the command: a span around a named function, in **Node.js (`.js`,
`.cjs`, `.mjs`)** and **Python**. Confirmed business metrics and database/queue coverage are not
part of it yet; say so if asked, and do not improvise them.

## Flags
- `<file>:<function>`: the file, and the function as `name` or `Class.method`. Required. If the
  user described the function in words instead, find it, then confirm the file and name with them
  before going on.
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
shared by every enrichment in that file and removed with the last one.

Two limits to state when they apply:
- A Node.js function that is not `async` but returns a promise: the span ends when the function
  returns, not when the promise settles (the script prints a `note:`).
- In Python, an exception that is part of normal flow (a framework's "400 Bad Request" exception,
  say) is still recorded as an error on the span.
