---
description: "Find out why part of this app is slow, times out, or fails only sometimes: time the suspect code on a local trace viewer and explain the cause from measured evidence. Nothing leaves this machine."
argument-hint: "\"<symptom in your own words>\" [--service <id>] [--route \"<METHOD> <path>\"] [--requests <N>]"
---

# /otel-why "<symptom>" [--service <id>] [--route "<METHOD> <path>"] [--requests <N>]

Someone says "checkout is slow" or "login times out sometimes" and has never read a trace. Measure
the code path behind that symptom, read the measurements back from the local stack, and explain
the cause from that evidence, in plain words.

Order matters, because reading code is tempting: in a trial run of exactly this task, an agent
that read the code first instrumented every function it already suspected, and once called a
span "CPU" when a span only measures elapsed time. So: **reading the code chooses where to
measure; the trace says what happened.** Never state a cause the evidence table does not show.

The user leaves with the baseline instrumentation in place (that is the point of the plugin) and
with no probes, unless they choose to keep them.

**Nothing leaves this machine.** This command talks only to `localhost`: the local stack, and the
service running on this machine. Never send a request to any other host, never point the service
at a remote endpoint, and never read traces from anywhere but the local stack.

## Flags
- `"<symptom>"`: the user's words, as given. Required; if missing, ask "What's slow or failing?"
- `--service <id>`: the service, as `/otel-instrument` Step 2 selects it otherwise.
- `--route "<METHOD> <path>"`: the request behind the symptom, when the user knows it.
- `--requests <N>`: how many requests the loop in Step 6 sends (default 20).

## Step 1: Load context and select the service

Exactly as `/otel-instrument` Steps 1 and 2: the freshness rule, a refresh merged into the cache
(never a replace), and service selection that never defaults to `services[0]`.

Probes need a helper this plugin writes, which exists for **Node.js (CommonJS)** and **Python**.
For any other language (or an ES-module Node.js service), say so in one line and continue with the
baseline alone: auto-instrumentation still times every inbound request, outbound HTTP call and
database query, which answers many "why is it slow" questions on its own.

## Step 2: Find the code behind the symptom

Turn the symptom into one request: the route and its handler. Use `--route` when given; otherwise
search the service's route definitions for the words in the symptom ("checkout" → the checkout
route; "login" → the login route). If two or more fit, list them and ask which one. If none fits,
ask the user which page or endpoint shows the problem.

Then read that handler's call path and shortlist the calls that could take time:
- loops that call something on each pass (one lookup per item: the "N+1" shape);
- outbound calls: HTTP, database, cache, queue;
- heavy computation: hashing, compression, parsing, image work, large sorts;
- waits: locks, sleeps, retries with backoff, connection pools.

Keep it to the 2 to 5 most likely. Write the shortlist down as **where to measure**, not as a
diagnosis.

## Step 3: Baseline instrumentation

If the service has no bootstrap (look as `/otel-instrument` Step 4 does), say "This service has no
instrumentation yet; I'll add the standard setup first, and it stays afterwards." and run
`/otel-instrument` for it, which confirms its own choices. Never write SDK setup here: the
baseline comes only from that generator.

## Step 4: Add the probes

Auto-instrumentation already times outbound HTTP and supported database drivers, so a probe is
for a shortlisted call it cannot see: a function in the app's own code (a loop's body, a
computation, a lock). If every shortlisted call is already covered, add no probes.

Show the plan and ask before editing anything:

```
To measure this I'll add <N> temporary timing spans (probes). They only record how long each call
takes; they don't change what the code does:
  <file>:<line>  <span name>    <why: the suspect, in a few words>
They're removed with /otel-uninstrument --probes, which puts these lines back exactly.
Add them? [y/N]
```

On yes:

1. Write the helper into the service's `rootDir`:
   `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/probes.py" helper --lang <nodejs|python> --dir <rootDir> --root <repo root>`
2. Write a probe spec (a JSON list) and apply it in one call:
   `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/probes.py" apply --spec <spec file> --root <repo root>`

Each probe is `{"id", "file", "find", "replace"}`. `find` is the exact original text (whole lines,
indentation included), unique in its file. `replace` is the same lines with the one call wrapped,
between marker lines for that id (`#` instead of `//` in Python):

```js
    // otel-as-code: probe begin get-product
    const product = await probe('db.getProduct', () => db.getProduct(item.sku));
    // otel-as-code: probe end get-product
```

```python
    # otel-as-code: probe begin sign-order
    signature = probe("orders.sign_order", sign_order, order)
    # otel-as-code: probe end sign-order
```

Add the helper's `require` / `import` to each probed file as its own probe, between markers too.
Rules:
- Wrap exactly one call; keep its arguments, its `await`, and what it returns. The probe changes
  timing data, never behavior.
- Name the span after the call, `<module>.<function>`, so the evidence table reads as the code does.
- Never probe inside a loop's condition or a hot inner loop body that runs thousands of times per
  request; probe the call the loop makes, or the loop as a whole.

`probes.py` checks every probe before writing any; on `REFUSED:` fix that probe and apply again.
Never edit a probed line by hand afterwards: removal restores only what it recorded.

## Step 5: Start or reuse the local stack

Run `/otel-local` for the service: it checks Docker, chooses ports, writes or reuses its two files,
and starts `grafana/otel-lgtm`, or finds it already running (its Step 3 port check recognises its
own stack). Skip its Step 7 walkthrough; this command reads the traces itself.

If Docker isn't available, `/otel-local` says so. Then stop, and say plainly: "Without the local
stack there are no traces to read, so I can't measure this. I can read the code and time it by
hand instead, but that is a guess from code, not trace evidence." Do that only if the user agrees,
and label everything that follows as not measured from traces.

## Step 6: Reproduce the symptom

Start the service with the load line `/otel-local` printed (it loads `otel-local.env`). If this
session can't run a background process, ask the user to start it in another terminal with that
line, and wait.

Then make the slow thing happen:
- **The loop**, only when the route is obvious and safe to repeat: a `GET`, or a request the user
  confirms is safe against their local data. Send `--requests` requests **one after another**
  (not in parallel, so the CPU figures stay per request) to `http://localhost:<port>` only:
  `for i in $(seq 1 <N>); do curl -s -o /dev/null -w '%{http_code} %{time_total}\n' <request>; done`
- **Otherwise**, ask: "Please use the app the way that's slow (or wait for it to time out), a few
  times, then tell me when you're done." For a symptom that happens "sometimes", ask for more tries.

Note the time the run started; Step 7 reads only traces from then on.

## Step 7: Read the evidence

Stop the service (or ask the user to) so its last spans are sent, then run:

```
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/trace_summary.py" --grafana http://localhost:<G> \
  --service <SERVICE_NAME> --route "<root span name>" --since <seconds since the run started> \
  --save-dir <a new temp directory>
```

The root span name is the server span auto-instrumentation gives the route, usually
`<METHOD> <route template>` (`POST /checkout`). If unsure, run
`python3 "${CLAUDE_PLUGIN_ROOT}/scripts/lgtm_check.py" traces --grafana http://localhost:<G> --service <SERVICE_NAME>`,
which prints the latest root span's name.

For a symptom that happens **sometimes** (times out sometimes, spikes, occasionally slow), run it a
second time with `--slowest 3`: the median over every request hides a slow minority.

Exit 1 means no matching traces: say what was checked (the script prints it) and the likely cause
(the service wasn't started with `otel-local.env`, the route name differs, or no request was
made), then retry once. Exit 2 means the stack is unreachable. Never describe traces that this
script did not return.

## Step 8: Evidence first, then what it means

Print the script's output **unchanged**, in a code block, under the heading "What the traces
show". Then, under "What this means", explain it in plain words. Rules:

- **Quote the table.** Every claim names its row (`#1 db.getProduct: 30 calls per request, one
  after another, 98% of the request`) or a line under the table. No numbers from anywhere else.
- **Elapsed is not CPU.** Say "computing", "CPU-bound" or "blocking" only when the table's CPU
  column and its "Elapsed vs CPU" line say so. Where there is no CPU figure, say the trace shows
  how long it took, not what it was doing.
- **Say what the trace can't show**, using the lines the script printed under the table, and
  suggest the next check it names.
- **If the summary says "Nothing stands out"**, say exactly that. Do not offer a cause. Suggest
  what would make the symptom show up: the slow case may need different data, a different user,
  more tries, or `--slowest`; or a probe one level further into the largest row.
- Explain any word the user hasn't seen the first time you use it: a span is one timed step of a
  request; self time is the time in that step itself, not in the steps it called.

Only after that, under "What you could change", may you suggest a fix, and you may read the code
for it, marked as a suggestion: "One way to fix it: load the products in one query instead of
one per item (see `lib/inventory.js`)." Never present the fix as measured.

## Step 9: Clean up

End with:

```
The standard instrumentation stays, so you can look at this service's traces any time:
  http://localhost:<G>  →  Explore  →  Tempo  →  Service Name = <SERVICE_NAME>
The <N> probes were only for this question. Remove them now? (/otel-uninstrument --probes) [Y/n]
The local stack is still running; stop it with /otel-local --down.
```

On yes, run `/otel-uninstrument --probes`. If no probes were added in Step 4, leave out the probe
line.
