---
description: Read-only audit of existing OTel coverage, semconv conformance, and cardinality risks
---

# /otel-evaluate

Read-only audit of existing OTel coverage. Does NOT write any application files.
Produces a structured gap analysis report.

## Step 1: Load context

Check `.claude/otel-context.json`. Apply the freshness rule from `/otel-init` Step 1
(identity-input fingerprint, not `HEAD`). If stale or absent, dispatch
`otel-as-code:repo-context-scanner` **passing the existing cache as `priorContext` and `scanTime`
(the output of `date -u +%Y-%m-%dT%H:%M:%SZ`)** and write
what it returns — a refresh is a merge, never a replace (see the cache ownership contract in
`agents/repo-context-scanner.md`).

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

## Step 3: Dispatch brownfield-auditor

Pass to `otel-as-code:brownfield-auditor`:
- `context`: loaded context JSON
- the list of read OTel source files, with their paths
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

## Step 4: Display the report

Print the audit report returned by the subagent verbatim.

**Write the audit's findings back into the cache — not only its refutations.** The auditor's
report distinguishes `refuted` / `corrected` / `confirmed` / `new` (see
`agents/brownfield-auditor.md`'s Output Format) for exactly this reason, but only `refuted` was
ever applied here: a `new` finding — one the scanner's own heuristics never caught (an unprefixed
custom attribute its naming rule can't see; a cardinality risk from where a value comes from
rather than its name) — was reported and then dropped on the floor, leaving `services[i].derived`
saying there was nothing even moments after the audit named it (#214, #193). Apply all four
statuses, scoped to `CV` (semconv violation) and `CR` (cardinality risk) findings — the other
categories (`SC`, `PI`, `CD`, `SH`, `WR`, `CF`, `MB`) have no `derived.*` field to land in yet:

- `refuted` — remove the matching entry from `services[i].derived.conformanceIssues` (unchanged).
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

## Step 5: Offer next steps (but do NOT apply them)

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
