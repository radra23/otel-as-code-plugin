---
name: otel-business-attrs
description: Infer and confirm service identity, ownership, and business-metric candidates from the repo, then write them to the context cache. Use to establish business attributes for instrumentation.
---

# otel-business-attrs (Codex bridge)

Follow the canonical procedure in this repo — it is the single source of truth:

1. Read `commands/otel-business-attrs.md` (repo root) and execute its steps.
2. Drive the confirmation UX with `skills/business-attr-ux/SKILL.md` (tiered confidence table,
   thresholds, conflict resolution).
3. Codex has no subagent dispatch: if the context cache is stale/absent, read
   `agents/repo-context-scanner.md` and run that scan yourself first.

Args: `$ARGUMENTS`.

Codex note: business attributes are ALWAYS presented for explicit confirmation before writing,
and every written `businessAttrs` entry must carry `"confirmed": true` (the plugin's
confirm-before-write hook does not auto-fire here).
