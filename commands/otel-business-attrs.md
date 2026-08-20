---
description: Infer and confirm service identity, ownership, and business-metric candidates
---

# /otel-business-attrs

Infer service identity, ownership, and candidate business metrics from the repo.
Present a tiered confirmation table. Write confirmed attributes to context cache.

## Step 1: Load the business-attr-ux skill

Read `otel-as-code:business-attr-ux` — follow all UX rules for this command.

## Step 2: Ensure context cache is current

Check `.claude/otel-context.json` gitHash vs `git rev-parse HEAD`.
If stale or absent, dispatch `otel-as-code:repo-context-scanner` and write the cache.

## Step 3: Run inference

For each service in context, derive attribute candidates and confidence scores:

**Tier 1 candidates (confidence ≥ 0.9 — auto-write):**
- `service.name` from `package.json#name` or `pyproject.toml [project].name` → 0.97
- `service.version` from `package.json#version` or `pyproject.toml [project].version` → 0.97

**Tier 2 candidates (confidence 0.5–0.9 — confirm):**
- `service.namespace` from parent directory name → 0.71
  (e.g. `services/payments/checkout-api` → namespace `payments`)
- `service.team` from CODEOWNERS matching the service root → 0.63
- `deployment.environment.name` — if CI config contains env keywords → 0.55

**Tier 3 / business candidates (always confirm):**
- Scan route definitions for POST/PUT handlers → candidate business transactions
  (e.g. `POST /checkout` → `biz.checkout.order_placed`)
- Scan metric-like variables (names containing `count`, `total`, `rate`) → candidate gauges/counters

**Custom namespace:**
- Determine namespace hint from context JSON `namespaceHint`
- If `namespaceHint` is null, ask: "What is your organization's reverse-DNS namespace?
  (e.g. com.myorg)" and persist the answer in the context JSON

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
  carry `"confirmed": true` (plus `name`, `source`, `confidence`, `confirmedAt`). Do NOT
  include rejected or unreviewed candidates — the `write-guard` hook blocks the entire write
  if any `businessAttrs` entry lacks `"confirmed": true`.

Print:
```
✓ Attributes confirmed and written to .claude/otel-context.json

Tip: Commit .claude/otel-services.json (not otel-context.json) to share
the service map with your team.
```
