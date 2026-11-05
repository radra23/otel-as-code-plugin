---
description: Read-only audit of existing OTel coverage, semconv conformance, and cardinality risks
argument-hint: "[--no-cache-write]"
---

# /otel-evaluate [--no-cache-write]

Read-only audit of existing OTel coverage. Does NOT write any application files.
Produces a structured gap analysis report.

## Flags
- `--no-cache-write` — scan into memory, audit, print the report, and write nothing to disk —
  not even `.claude/otel-context.json` (#212). The report itself has always been read-only; by
  default the RUN was not, because a stale-or-absent cache still gets scanned and written in
  Step 1, and Step 5 can still write audit findings back into the cache. Use this flag when
  evaluating someone else's repo, or any repo under a policy that nothing may be committed or
  left dirty, and no cache should exist on disk afterward either. Without it, behavior is
  unchanged from before this flag existed.

## Step 1: Load context

Check `.claude/otel-context.json`. Apply the freshness rule from `/otel-init` Step 1
(identity-input fingerprint, not `HEAD`). If stale or absent, dispatch
`otel-as-code:repo-context-scanner` **passing the existing cache as `priorContext`, `scanTime`
(the output of `date -u +%Y-%m-%dT%H:%M:%SZ`), and `pluginVersion` (the `version` field from
`${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json`)**.

**Without `--no-cache-write`:** write what the scanner returns via `scripts/write_context.py`,
exactly as `/otel-init` Step 4 does (#211) — never by transcribing the JSON into a `Write` call. A
refresh is a merge, never a replace (see the cache ownership contract in
`agents/repo-context-scanner.md`).

**With `--no-cache-write` (#212):** keep the scanner's JSON in context for the rest of this run
and skip `write_context.py` entirely — `.claude/otel-context.json` is left exactly as it was
found (absent stays absent; present and stale stays stale on disk, even though this run audits
the fresh in-memory result). Every later step in this command reads from the in-memory result,
not from disk, so this does not change what gets audited or printed — only whether anything
lands on the filesystem.

If the scan or the cache has **no services**, apply `/otel-init` Step 2's "Empty scan" rule:
print its message, write nothing, exit 0. Do this before the check below: "every service reports
no OTel" is vacuously true over an empty list, and it would send the user to `/otel-instrument`,
which cannot do anything here either.

Then decide whether there is anything to audit. If every service reports
`existingOtel.hasTraces = false` AND `hasMetrics = false` AND `hasLogs = false`, **verify that
on disk before believing it.** These flags are only as fresh as the last scan, and a cache that
predates `/otel-instrument` still says `false` — so the obvious sequence (instrument, then
evaluate) otherwise exits claiming the repo has no instrumentation moments after generating it.

Verification is cheap: check for an OTel dependency in each service's manifest (including
`*.csproj`/`*.fsproj`/`Directory.Packages.props` for .NET) and glob its subtree for
`tracing.*` / `telemetry.*` / `opentelemetry.*`:

```
grep -il '@opentelemetry/\|opentelemetry-\|Include="OpenTelemetry' <manifests>
```

The grep is **case-insensitive** (`-i`) and includes the .NET spelling on purpose: the .NET
package id is `OpenTelemetry` (capitalised, no `/`, no trailing `-`), so the Node/Python
alternatives alone silently miss a fully-instrumented .NET service and the command wrongly exits
"no instrumentation". Also grep the `*.cs` sources for `AddOpenTelemetry(` / `ActivitySource` /
`new Meter(` when the manifest matches, so a .NET service is audited from disk.

- If that finds nothing either, print "No existing OTel instrumentation detected. Use
  /otel-instrument to get started." and exit.
- If it finds something the cache does not reflect, the cache is wrong, not the repo. Say so —
  "cache reported no instrumentation but `api/src/tracing.ts` exists; auditing from disk" —
  refresh `existingOtel` for that service, and continue.

## Step 2: Collect existing OTel files

Build the read list in this order. **`sdkPackages` is not part of it**: it holds npm/PyPI
specifiers (`@opentelemetry/sdk-node@^0.221.0`), not paths, and there is nothing there to open.

1. `context.services[i].existingOtel.bootstrapFiles` — the files that construct or configure
   the SDK. This is the field that answers the question, and it is populated by the scanner.
   Add `existingOtel.apiCallSites`: hand-written files that use or extend OTel (API call sites,
   custom processors, the data files behind them). They are not bootstrap, but an audit that
   skips them misses real findings and miscounts who calls what.
2. `context.services[i].existingOtel.wiredInto` plus the service's `runnableEntry` — an audit
   has to see whether the bootstrap is actually reached. A helper that no file imports is
   instrumentation that never runs, and that is invisible if you only read the bootstrap.
   **`runnableEntry` is not always a repo file** — for `framework: nextjs` with no bootstrap yet,
   the scanner records the process-entry descriptor (`"next start"`, or
   `".next/standalone/server.js"` for a standalone build) instead, flagged in `derived.notes` as
   build output / not a repo file (#170). Check `derived.notes` for that flag before calling
   `Read` on it; skip the read (there is nothing to audit — no bootstrap exists) rather than
   erroring on a path that was never meant to be opened.
3. Files named in `derived.conformanceIssues[].file` — these carry an already-known problem, so
   they are the *last* place to look for new ones, not the first.

If `bootstrapFiles` is empty but Step 1 found OTel on disk, glob the service subtree yourself
rather than auditing nothing.

Read each file with the Read tool.

**Resolve `gitFileStatus` for every file in this read list (#222).** The auditor's dimension 8
(credential exposure) needs to know whether each file is git-tracked and gitignored, but the
auditor has no `Bash` tool and cannot run `git` itself — this command can, so do it here rather
than let the auditor guess or skip it:

```bash
for f in <each file in the read list>; do
  tracked=false; git ls-files --error-unmatch "$f" >/dev/null 2>&1 && tracked=true
  gitignored=false; git check-ignore -q "$f" && gitignored=true
  # record gitFileStatus[f] = {tracked, gitignored}
done
```

Build `gitFileStatus` as `{"<file>": {"tracked": bool, "gitignored": bool}}` for every file read
above; pass it to the auditor in Step 4.

## Step 3: Verify the bootstrap actually initializes

The auditor has **no `Bash` tool** (`Read`, `Grep`, `Glob` only), so it can only read whether a
bootstrap's setup call is wrapped in a `try`/`except` (or `try`/`catch`) — it cannot tell whether
that wrapper is CATCHING something. A setup function that raises and is silently swallowed
leaves every provider on the OTel API's own no-op default: the app keeps running, nothing throws,
and from source alone this reads identical to a correctly-guarded, correctly-initialized
bootstrap. Reading `try`/`except` as a clean bill of health is exactly backwards — it is a reason
to verify, not a reason to skip verifying (#194). This command has `Bash`; the auditor does not,
so this check runs here and is passed down as a fact.

Applies to **Node.js and Python** bootstraps only (the two the bug was reported against); skip
for other languages. For each service with a non-empty `existingOtel.bootstrapFiles`:

Run the smoke only if the SDK dependencies are installed (`node_modules` / the venv present). If
not, DO NOT fail and DO NOT assume health — record `{"checked": false}` for that service and say
verification was skipped. (Mirrors `/otel-instrument` Step 7's deferral, but the stakes differ: a
deferred check there means "unverified since generation"; here it means "unknown — do not let the
auditor imply this is healthy" #194.)

The check: import the bootstrap, then ask each provider whether it is a REAL SDK-registered
provider or still the API package's own no-op/proxy default. Verified empirically (Python
`opentelemetry` 1.x, Node `@opentelemetry/api` 1.x): the default placeholder for every one of
traces/metrics/logs lacks a working `shutdown` method; the real SDK-registered provider in both
languages always has one. This is more robust than checking a class name (names drift across SDK
versions — this project's own earlier attempt via `addSpanProcessor` did not survive contact with
the installed package; `shutdown` did). Re-verify against the installed version if this ever
looks wrong — do not assume it holds forever.

- **Python** (`cd` to the service's `rootDir` first; adjust the import to the bootstrap's module
  name without `.py`):
  ```
  python -c "
  import <bootstrap_module>
  from opentelemetry import trace, metrics
  from opentelemetry import _logs
  report = {}
  for signal, provider in (
      ('traces', trace.get_tracer_provider()),
      ('metrics', metrics.get_meter_provider()),
      ('logs', _logs.get_logger_provider()),
  ):
      report[signal] = hasattr(provider, 'shutdown')
  print(report)
  "
  ```
- **Node.js** (adjust the `require` path to the bootstrap file; `@opentelemetry/api-logs` may not
  be a dependency — fall back to `{logs: null}` if the `require` throws):
  ```
  node -e "
  require('./tracing.js');
  const { trace, metrics } = require('@opentelemetry/api');
  const report = {
    traces: typeof trace.getTracerProvider().shutdown === 'function',
    metrics: typeof metrics.getMeterProvider().shutdown === 'function',
  };
  try {
    const { logs } = require('@opentelemetry/api-logs');
    report.logs = typeof logs.getLoggerProvider().shutdown === 'function';
  } catch { report.logs = null; }
  console.log(JSON.stringify(report));
  "
  ```

If the import itself throws (an escaping exception — the bootstrap has no fallback, or the
fallback itself is broken), that is a DIFFERENT, more severe finding the auditor's existing
checks already cover (a throw that breaks the app); record `{"checked": true, "importError":
"<message>"}` for that service and let the auditor's own dimension 6 report it.

Record the result per service as `bootstrapHealth[serviceId]` — `{"checked": bool, "traces":
bool|null, "metrics": bool|null, "logs": bool|null}` (or the `importError` shape above) — to pass
to the auditor in Step 4.

## Step 4: Dispatch brownfield-auditor

Pass to `otel-as-code:brownfield-auditor`:
- `context`: loaded context JSON
- the list of read OTel source files, with their paths
- `scanTime`: run `date -u +%Y-%m-%dT%H:%M:%SZ` right before this dispatch and pass its output
  (#226). The auditor has no clock — without this it stamps its report's `Scanned:` line from
  memory, which reads as a plausible date but isn't the real one, exactly the #202/#177 failure
  shape this plugin avoids everywhere else a subagent needs the current time.
- `semconvVersion`: the `SEMCONV_VERSION` from the `semconv-discipline` skill (read it here — the
  auditor has no `Skill` tool, and without this it stamps a version from memory: a report that
  read `1.27.0` while the pin was `1.44.0` is exactly the failure to prevent).
- `semconvGuidancePath`: `${CLAUDE_PLUGIN_ROOT}/skills/semconv-discipline/SKILL.md` — the auditor
  `Read`s it for the OLD→NEW attribute table and the high-cardinality list.
- `languageMaturityPath`: `${CLAUDE_PLUGIN_ROOT}/skills/language-maturity/SKILL.md` — the auditor
  `Read`s it (no `Skill` tool of its own) to check each service's installed instrumentation
  packages against the per-runtime maturity matrix and flag any that are below Stable while their
  siblings are Stable (e.g. a Beta-pinned `OpenTelemetry.Instrumentation.EntityFrameworkCore`).
  Mirrors what `/otel-instrument` already passes its generator subagent.
- `cachedJudgements`: `services[i].derived` for each service — passed explicitly as **claims to
  re-verify, not findings to inherit**. Include each block's `guidanceVersion` so the auditor
  can see which predate the current `SEMCONV_VERSION`.
- `bootstrapHealth`: the per-service result from Step 3 — passed as a **fact the auditor cannot
  derive itself** (it has no `Bash` tool), the same relationship `cachedJudgements` has, just in
  the opposite direction: that one is a claim to re-verify, this one is a verification already
  done. `checked: false` means "unknown", not "healthy" — the auditor must say verification was
  skipped, never imply a clean bill of health from an absent check (#194).
- `gitFileStatus`: the map built in Step 2 — another fact the auditor cannot derive itself (no
  `Bash` tool), used by dimension 8 (credential exposure) (#222).

## Step 5: Display the report

**First, resolve the "ever-committed" fact the auditor deferred (#222).** For each `[CD-...]`
finding in the report (dimension 8, credential exposure), the auditor named a file:line but could
not run `git log --all -S'<literal>'` itself (no `Bash` tool) — and should not have echoed the
literal into its own report just to make this checkable later. Re-read that exact file:line
yourself (you already have `Read`), extract the value at that location, and run:

```bash
git log --all -S'<the literal you just read>' --oneline | head -1
```

If that prints a commit, the key has been committed at some point regardless of its current
`tracked`/`gitignored` state — upgrade that finding's severity to `CRITICAL` ("real credential
committed to history") in the printed output and show the commit as evidence. If it prints
nothing, annotate the finding as "ever-committed: no (confirmed)" rather than leaving the
auditor's "not checked" wording, since it has now been checked. Do this before printing anything
below — a reader should never see a MEDIUM credential finding that a quick history search would
have shown is actually an incident.

Print the audit report returned by the subagent verbatim, with the Step 5 annotations above
applied to any `[CD-...]` findings.

**With `--no-cache-write` (#212), stop here — do not write anything below.** The report has
already been printed from the in-memory result; writing the findings back would be the one
filesystem write this flag exists to prevent, including on a repo where `.claude/otel-context.json`
did not exist before this run.

**Without the flag: write the audit's findings back into the cache — not only its refutations.**
The auditor's
report distinguishes `refuted` / `corrected` / `confirmed` / `new` (see
`agents/brownfield-auditor.md`'s Output Format) for exactly this reason, but only `refuted` was
ever applied here: a `new` finding — one the scanner's own heuristics never caught (an unprefixed
custom attribute its naming rule can't see; a cardinality risk from where a value comes from
rather than its name) — was reported and then dropped on the floor, leaving `services[i].derived`
saying there was nothing even moments after the audit named it (#214, #193). Apply all four
statuses, scoped to `CV` (semconv violation) and `CR` (cardinality risk) findings — the other
categories (`SC`, `PI`, `CD`, `SH`, `WR`, `CF`, `MB`) have no `derived.*` field to land in yet:

- `refuted` on a **`CV`** (conformanceIssues) finding — **set `"refuted": true` and
  `"refutedAt": "<the real date -u output>"` on the matching entry; do NOT delete it (#226).**
  Deleting it drops the only record that this claim was ever considered — the next scanner
  rescan has nothing to carry forward (see the scanner's own carry-forward rule in
  `agents/repo-context-scanner.md`), and the next audit has nothing in `cachedJudgements` to
  re-confirm, so the same false claim can resurface with no memory it was already settled. A
  `refuted: true` entry is EXCLUDED from any "how many conformance issues" count or warning
  surfaced elsewhere (it is retained history, not an active finding) — only `brownfield-auditor`'s
  "Cached judgements re-checked" block ever renders it, never as a live finding.
- `refuted` on a **`CR`** (highCardinalityAttributes) finding — remove the key from the list
  (unchanged): this list is bare attribute-name strings, not objects, so there is no per-entry
  shape to attach a retained refutation to without a larger schema change this issue does not
  need; a cardinality false-positive is cheap to re-derive fresh on the next scan if it recurs.
- `new` — add it. A `CV` finding appends to `conformanceIssues`: `file`, `line`, `violation`,
  `severity`, and `"source": "auditor"` (see the cache ownership contract in
  `agents/repo-context-scanner.md` — this is how a reader tells it apart from a scanner-found
  entry). A `CR` finding appends the bare attribute key (e.g. `user.id`, not the whole sentence)
  to `highCardinalityAttributes` if not already present. Dedup `conformanceIssues` by
  `(file, violation)` and `highCardinalityAttributes` by the key itself — never add the same
  entry twice across a scanner-sourced and an auditor-sourced finding.
- `corrected` — update the matching entry's `violation`/`line` in place; do not duplicate it.
- `confirmed` — no write needed; the entry is already correct in the cache.

Run `date -u +%Y-%m-%dT%H:%M:%SZ` and set that service's `derived.derivedAt` to it whenever you
write anything above, so a later command can tell this judgement reflects THIS audit, not the
last scan. Skip the cache write entirely if the auditor returned no `new`/`refuted`/`corrected`
`CV`/`CR` findings — printing the report is enough when nothing changed.

## Step 6: Offer next steps (but do NOT apply them)

This report is read-only. Print the finding IDs alongside the options, so applying a subset is
possible:

```
This report is read-only. To apply what it found:

  /otel-instrument --fix SC-2,SH-1     apply just these findings, in place
  Edit manually                        see the file:line references above

  /otel-instrument --force             ⚠ FULL regeneration of the bootstrap files.
                                       This overwrites them, discarding hand edits.
```

**If the audited service has `generatorSupported: false`** (a third-party binary/image with no
application source — see `deployment-remediation/SKILL.md`), `/otel-instrument` is not the next
step at all; it explicitly refuses this service. Point at the deployment-config equivalent
instead:

```
This report is read-only. <name> has no application source for /otel-instrument to bootstrap —
to apply what it found:

  /otel-remediate --service <id>       propose a deployment-config diff (env vars) for this
                                       service's native OTel support (v1: Keycloak only)
```

If the target isn't one `/otel-remediate` v1 supports (anything other than Keycloak today), say
so plainly rather than offering a command that will just refuse — name the findings as manual
work: "no automated remediation path yet for this target; apply the findings above by hand."

**If the service is existing Collector infrastructure** (the scanner's `instrumentableReason`
says so — see "Terraform helm_release / kubernetes_manifest" in `repo-context-scanner.md`, #176),
do NOT offer `/otel-remediate` — there is nothing to remediate on a Collector the way there is on
Keycloak; it already routes telemetry, it does not need instrumenting. Acknowledge it plainly
instead:

```
<name> is existing OTel Collector infrastructure (chart <chart>, image <image>), defined in
<file> — not a telemetry source to instrument or a /otel-remediate target. This is why it showed
up here rather than nothing: a repo whose only OTel footprint is infra like this would otherwise
report "no OTel detected" with services: [], which is wrong.

If /otel-collector would generate a new config for this repo, check this release's own `values`
first — editing it directly may be more appropriate than adding a second, disconnected config.
```

This is also the fix for the specific failure mode #176 reported: an infra-only repo (no
application source anywhere) used to come back with an empty `services` list and hit the
"Empty scan" exit in `/otel-init` Step 2 before ever reaching this command's own checks above —
the scanner creating this entry at all is what keeps that path from firing.

**Say the `--force` caveat plainly; do not offer it as the default route.** By the time an audit
is worth running, the bootstrap has usually been hand-refined, and this report is often the
evidence that those refinements are *correct* — a handler wrapper for a runtime with no inbound
HTTP server, a `none` exporter path, a bounded `error.type`, a deliberately excluded liveness
probe. A literal `--force` discards all of it, and the closing recommendation of the audit would
be what caused the loss.

So when the audit confirmed local decisions as correct, name them here, e.g.:

```
  Before any --force: this audit confirmed 12 deliberate decisions in api/src/telemetry.ts
  as correct. Regeneration will not reproduce them. Back the file up, or use --fix.
```

The write-guard hook will still prevent an accidental overwrite without `--force`.
