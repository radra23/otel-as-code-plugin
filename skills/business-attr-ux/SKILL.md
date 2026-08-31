---
name: business-attr-ux
description: Tiered confidence-table UX, confidence thresholds, and conflict-resolution protocol for confirming inferred service identity and business attributes. Use from /otel-business-attrs.
version: 0.1.0
---

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
Any candidate business metric or business attribute is ALWAYS presented as Tier 2 (approval
required), regardless of confidence score. Business semantics are NEVER assumed. This rule
overrides the Tier 1 threshold.

**`biz.` is a placeholder, never a name that gets written.** Inference produces a bare
shape like `biz.checkout.conversion_rate`, but `semconv-discipline` requires every custom
attribute to carry a reverse-DNS prefix and names bare prefixes as WRONG. Both rules cannot be
followed at once, so resolve it before the user sees the row rather than after they approve it:

- If `namespaceHint` is known (or the user has supplied a namespace), **present candidates
  already namespaced** — `com.myorg.checkout.conversion_rate`. What the user approves is then
  exactly what gets written.
- If no namespace is known yet, ask for it *before* presenting business candidates. That
  question is Step 3 of `/otel-business-attrs`; run it first when there are candidates to show.
- If a candidate is somehow shown as `biz.*`, say in the same breath that `biz.` is a
  placeholder that will be replaced at write time, and record the pre-namespace form as
  `candidateName` alongside the final `name`.

Never write a bare `biz.*` name to the context cache: it is non-conformant, and the user
approved a different string than the one that reaches disk.

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

● Business attributes (always confirm) — namespace com.myorg:
  #  Attribute                              Candidate             Source
  1  com.myorg.checkout.conversion_rate     route POST /checkout   AST inference

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

`agents/repo-context-scanner.md` owns the context-JSON schema — do not restate it here, or the
two copies drift and later commands read whichever they happen to find. This section covers
only the fields **this** skill is responsible for producing.

On approval, update `.claude/otel-context.json` in place, changing only:

```json
{
  "namespace": "com.myorg",
  "deploymentEnvironment": "production",
  "confirmedAt": "<ISO-8601 timestamp>",
  "businessAttrs": [
    {
      "name": "com.myorg.checkout.conversion_rate",
      "candidateName": "biz.checkout.conversion_rate",
      "source": "route POST /checkout (AST inference)",
      "confidence": 0.42,
      "confirmed": true,
      "confirmedAt": "<ISO-8601 timestamp>"
    }
  ]
}
```

and, per service, the identity fields the user confirmed:

```json
{
  "namespace": "payments",
  "namespaceSource": "user-confirmed",
  "namespaceConfidence": 0.71,
  "team": "@payments-team",
  "teamSource": "user-confirmed",
  "teamConfidence": 0.63
}
```

plus `resolvedValue` / `resolvedSource` / `resolvedAt` / `"conflict_resolved": true` on each
entry in `conflicts` the user settled.

All of these are **user-owned** fields in the cache ownership contract: a later re-scan carries
them over verbatim and must never reset them to `null` or `[]`. Mark a confirmed namespace or
team `"user-confirmed"` as its source — that marker is what tells the scanner not to overwrite
it with a fresh inference.

Every object in `businessAttrs` MUST include `"confirmed": true` — the `write-guard` hook
rejects the whole file otherwise. Omit attributes the user rejected or did not review; never
write them with `"confirmed": false` expecting them to be ignored. Never write a bare `biz.*`
name; keep the pre-namespace form in `candidateName`.
