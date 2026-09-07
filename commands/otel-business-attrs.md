---
description: Infer and confirm service identity, ownership, and business-metric candidates
---

# /otel-business-attrs

Infer service identity, ownership, and candidate business metrics from the repo.
Present a tiered confirmation table. Write confirmed attributes to context cache.

## Step 1: Load the business-attr-ux skill

Read `otel-as-code:business-attr-ux` — follow all UX rules for this command.

## Step 2: Ensure context cache is current

Check `.claude/otel-context.json`. Apply the freshness rule from `/otel-init` Step 1
(identity-input fingerprint, not `HEAD`). If stale or absent, dispatch
`otel-as-code:repo-context-scanner` **passing the existing cache as `priorContext`** and write
what it returns — a refresh is a merge, never a replace (see the cache ownership contract in
`agents/repo-context-scanner.md`).

## Step 3: Run inference

For each service in context, derive attribute candidates and confidence scores:

**`service.name` is already resolved — do not re-derive it here.** The scanner resolved it under
its own observed-name ladder (`agents/repo-context-scanner.md`: `OTEL_SERVICE_NAME`/IaC >
bootstrap literal > Dockerfile LABEL > manifest name > directory name) and recorded it as
`services[i].name`, with `nameSource`/`nameConfidence`, plus a `conflicts[]` entry if a source
disagreed with the resolved value. Read `services[i].name` as-is for the Auto-applied block in
Step 5. Computing a competing answer from a manifest here (as this step used to) is exactly how
#132 happened: it silently overwrote an already-correct observed name (e.g. `bootstrap-literal`
or `env:OTEL_SERVICE_NAME`) with a stale manifest name at auto-write confidence, on the same
service #57 had already fixed the scanner for. If `context.conflicts` names this service, run
the conflict-resolution protocol in Step 4 — never resolve it in this step.

**Tier 1 candidates (confidence ≥ 0.9 — auto-write):**
- `service.version` from the language's manifest → 0.97:
  - `nodejs`: `package.json#version`
  - `python`: `pyproject.toml [project].version`
  - `dotnet`: `*.csproj`'s `<Version>`
  - `ruby`: `*.gemspec`'s `spec.version` (a bare `Gemfile` rarely carries a version)
  - `java`: `pom.xml`'s `<version>`
  - `go`: no manifest source. `go.mod` has no package-version field — Go module versions come
    from VCS tags, not the manifest — so omit `service.version` for `go` rather than guessing.
    Do NOT fall back to `languageVersion`; that is the Go toolchain version, a different thing.

**Tier 2 candidates (confidence 0.5–0.9 — confirm):**
- `service.namespace` from parent directory name → 0.71
  (e.g. `services/payments/checkout-api` → namespace `payments`)
- `service.team` from CODEOWNERS matching the service root → 0.63
- `deployment.environment.name` — if CI config contains env keywords → 0.55

**Custom namespace — resolve this BEFORE presenting any business candidate:**
- Determine namespace hint from context JSON `namespaceHint`
- If `namespaceHint` is null, ask: "What is your organization's reverse-DNS namespace?
  (e.g. com.myorg)" and persist the answer in the context JSON
- Business candidates are presented already prefixed with it, so the string the user approves
  is the string that gets written (see `business-attr-ux`). A bare `biz.*` name is a
  placeholder, never a value to write — `semconv-discipline` requires the reverse-DNS prefix.

**Tier 3 / business candidates (always confirm):**
- Scan route definitions for POST/PUT handlers → candidate business transactions
  (e.g. `POST /checkout` → `<namespace>.checkout.order_placed`)
- Scan metric-like variables (names containing `count`, `total`, `rate`) → candidate gauges/counters

## Step 4: Check for conflicts

If `context.conflicts` is non-empty, run the conflict resolution protocol from
the `business-attr-ux` skill for each conflict before presenting the main table.

## Step 5: Present the tiered confirmation table

Follow the exact table format from the `business-attr-ux` skill.
Wait for user input. Process actions (A/E/R/number) as specified in the skill.
Do not proceed until all Tier 2 rows have been explicitly acted on.

## Step 6: Write confirmed attributes

Update `.claude/otel-context.json`:
- Merge approved attributes into `services[i]`
- Set `confirmedAt` to current ISO-8601 timestamp
- Add a `businessAttrs` array containing ONLY approved business attributes. Each entry MUST
  carry `"confirmed": true` and a confirmed `"kind"` (`"counter"`, `"gauge"`, or `"dimension"` —
  see `business-attr-ux`; it decides how `/otel-backend` renders the attribute), plus `name`,
  `source`, `confidence`, `confirmedAt`. Do NOT include rejected or unreviewed candidates — the
  `write-guard` hook blocks the entire write if any `businessAttrs` entry lacks
  `"confirmed": true`.

Print:
```
✓ Attributes confirmed and written to .claude/otel-context.json

Tip: Commit .claude/otel-services.json (not otel-context.json) to share
the service map with your team.
```
