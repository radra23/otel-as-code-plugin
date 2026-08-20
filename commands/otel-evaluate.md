---
description: Read-only audit of existing OTel coverage, semconv conformance, and cardinality risks
---

# /otel-evaluate

Read-only audit of existing OTel coverage. Does NOT write any application files.
Produces a structured gap analysis report.

## Step 1: Load context

Check `.claude/otel-context.json`. Run inline scan if stale/absent.

If context shows no existing OTel (`existingOtel.hasTraces = false` AND
`existingOtel.hasMetrics = false` AND `existingOtel.hasLogs = false`):
- Print: "No existing OTel instrumentation detected. Use /otel-instrument to get started."
- Exit.

## Step 2: Collect existing OTel files

From `context.services[i].existingOtel.sdkPackages` and `conformanceIssues`,
build a list of files to read. Read each file using the Read tool.

## Step 3: Dispatch brownfield-auditor

Pass to `otel-as-code:brownfield-auditor`:
- `context`: loaded context JSON
- List of read OTel source files

## Step 4: Display the report

Print the audit report returned by the subagent verbatim.

## Step 5: Offer next steps (but do NOT apply them)

```
This report is read-only. To apply recommended fixes:
  /otel-instrument --force   (rewrites bootstrap files)
  Edit violations manually   (see specific file:line references above)

The write-guard hook will prevent accidental overwrites without --force.
```
