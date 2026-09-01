---
description: Read-only audit of existing OTel coverage, semconv conformance, and cardinality risks
---

# /otel-evaluate

Read-only audit of existing OTel coverage. Does NOT write any application files.
Produces a structured gap analysis report.

## Step 1: Load context

Check `.claude/otel-context.json`. Apply the freshness rule from `/otel-init` Step 1
(identity-input fingerprint, not `HEAD`). If stale or absent, dispatch
`otel-as-code:repo-context-scanner` **passing the existing cache as `priorContext`** and write
what it returns — a refresh is a merge, never a replace (see the cache ownership contract in
`agents/repo-context-scanner.md`).

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

1. `context.services[i].existingOtel.bootstrapFiles` — the SDK bootstrap and any helper module
   beside it. This is the field that answers the question, and it is populated by the scanner.
2. `context.services[i].existingOtel.wiredInto` plus the service's `runnableEntry` — an audit
   has to see whether the bootstrap is actually reached. A helper that no file imports is
   instrumentation that never runs, and that is invisible if you only read the bootstrap.
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
- `cachedJudgements`: `services[i].derived` for each service — passed explicitly as **claims to
  re-verify, not findings to inherit**. Include each block's `guidanceVersion` so the auditor
  can see which predate the current `SEMCONV_VERSION`.

## Step 4: Display the report

Print the audit report returned by the subagent verbatim.

If the auditor refuted a cached judgement, that correction matters as much as the new findings:
update `services[i].derived` in the cache so the wrong entry does not outlive this run and get
re-read as authoritative by the next command.

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
