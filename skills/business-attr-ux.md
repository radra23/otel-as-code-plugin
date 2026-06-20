# Business Attribute Inference UX

## Confidence Tiers

### Tier 1 — Auto-write (confidence ≥ 0.9)
Write immediately. Show a collapsed "✓ Auto-applied" block so the user can
see what was written without being asked to confirm it.

Example sources that reach Tier 1:
- `service.name` from `package.json#name` → confidence 0.97
- `service.version` from `package.json#version` → confidence 0.97
- `service.name` from `pyproject.toml [project].name` → confidence 0.97

### Tier 2 — Confirm (0.5–0.9)
Show in an approval table. Each row shows: attribute | proposed value | confidence | source.
Each row has three actions: **[A]pprove / [E]dit / [R]emove**.
User must explicitly approve before any Tier 2 value is written.

Example sources that reach Tier 2:
- `service.namespace` from directory structure → confidence 0.71
- `service.team` from CODEOWNERS → confidence 0.63 (CODEOWNERS may be stale)
- `deployment.environment.name` from CI config → confidence 0.55

### Tier 3 — Propose (confidence < 0.5)
Show as flagged proposals. NEVER write without explicit user action.
User must promote to Tier 2 by typing the row number (this acts as immediate approval — no second confirmation needed) or reject by typing 'r <number>'.

Example sources that reach Tier 3:
- Business transaction name inferred from route analysis → confidence 0.35–0.45
- Domain inferred from git remote URL → confidence 0.40

### Business Attributes — Always Confirm
Any attribute in the `biz.*` namespace, or any candidate business metric,
is ALWAYS presented as Tier 2 (approval required), regardless of confidence score.
Business semantics are NEVER assumed. This rule overrides the Tier 1 threshold.

**Enforced, not just requested.** Each `businessAttrs` entry written to
`.claude/otel-context.json` MUST carry `"confirmed": true`, set only after the user
explicitly approves it. The `write-guard` PreToolUse hook parses every write to
`otel-context.json` and BLOCKS it if any business attribute is missing `"confirmed": true`.
So an unconfirmed business attribute cannot reach disk even if this prose is ignored — write
approved attributes with `"confirmed": true`, and never write rejected/unreviewed ones.

## Confidence Thresholds

```
AUTO_WRITE_THRESHOLD = 0.9
CONFIRM_THRESHOLD    = 0.5
```

These are calibrated constants. Do not change them without user instruction.

## Presenting the Confirmation Table

Format:

```
✓ Auto-applied (confidence ≥ 0.90):
  service.name     = "checkout-api"    [0.97 · package.json#name]
  service.version  = "1.4.2"           [0.97 · package.json#version]

⚠ Needs your approval (confidence 0.50–0.89):
  #  Attribute               Proposed Value       Conf  Source
  1  service.namespace       "payments"           0.71  dir: services/payments/
  2  service.team            "@payments-team"     0.63  CODEOWNERS line 4

Actions: [A]pprove all  [number] approve one  [E number] edit  [R number] remove
→

● Business attributes (always confirm):
  #  Attribute                       Candidate                   Source
  1  biz.checkout.conversion_rate    route POST /checkout         AST inference

Actions: [A]pprove  [R number] reject
→
```

After the user responds:
- "a" or "A" → approve all items in that tier
- A number (e.g. "1") → approve that specific item
- "e 2" → edit item 2 (ask for new value inline)
- "r 1" → remove item 1 from the proposal

Do NOT proceed to write until all Tier 2 items have been explicitly acted on.

## Conflict Resolution Protocol

When multiple sources disagree on the same attribute value, show a conflict block:

```
⚡ Conflict: service.name
  1. package.json#name   → "checkout-api"    [confidence 0.97]
  2. repo path           → "services/cart"   [confidence 0.70]
  3. Dockerfile LABEL    → "cart-service"    [confidence 0.88]

  Pick a number, or type a custom value:
  →
```

Rules:
- NEVER silently pick one source. Always surface the conflict.
- Write the chosen value with `"conflict_resolved": true` in the context JSON.
- The conflict itself is diagnostic — it indicates the team has not aligned on a service name.
  Add a comment in the written manifest pointing this out.

## Written Output Format

On approval, write (or update) `.claude/otel-context.json`:

```json
{
  "schemaVersion": "1",
  "scannedAt": "<ISO-8601 timestamp>",
  "gitHash": "<current HEAD commit hash>",
  "pluginVersion": "0.1.0",
  "services": [
    {
      "id": "checkout-api",
      "name": "checkout-api",
      "nameSource": "package.json#name",
      "nameConfidence": 0.97,
      "rootDir": ".",
      "language": "nodejs",
      "languageVersion": "20",
      "framework": "express",
      "hasDockerfile": true,
      "existingOtel": {
        "hasTraces": false,
        "hasMetrics": false,
        "hasLogs": false,
        "sdkVersion": null,
        "sdkPackages": [],
        "conformanceIssues": []
      },
      "namespace": "payments",
      "namespaceSource": "dir-structure",
      "namespaceConfidence": 0.71,
      "team": "@payments-team",
      "teamSource": "CODEOWNERS",
      "teamConfidence": 0.63
    }
  ],
  "conflicts": [],
  "namespaceHint": "com.myorg",
  "namespaceSource": "npm-scope",
  "businessAttrs": [
    {
      "name": "biz.checkout.conversion_rate",
      "source": "route POST /checkout (AST inference)",
      "confidence": 0.42,
      "confirmed": true,
      "confirmedAt": "<ISO-8601 timestamp>"
    }
  ],
  "confirmedAt": "<ISO-8601 timestamp>"
}
```

Every object in `businessAttrs` MUST include `"confirmed": true` — the `write-guard` hook
rejects the whole file otherwise. Omit attributes the user rejected or did not review; never
write them with `"confirmed": false` expecting them to be ignored.
