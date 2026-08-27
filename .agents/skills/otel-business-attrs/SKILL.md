---
name: otel-business-attrs
description: Infer and confirm service identity, ownership, and business-metric candidates from the repo, then write them to the context cache. Use to establish business attributes for instrumentation.
---

# otel-business-attrs (Codex bridge)

> **Requires the otel-as-code repo.** The `commands/` / `skills/` / `agents/` files referenced below live there — if they're not present in your workspace, stop and tell the user to add the repo (see AGENTS.md).

Follow the canonical procedure in this repo — it is the single source of truth:

1. Read `commands/otel-business-attrs.md` (repo root) and execute its steps.
2. Drive the confirmation UX with `skills/business-attr-ux/SKILL.md` (tiered confidence table,
   thresholds, conflict resolution).
3. Codex has no subagent dispatch: if the context cache is stale/absent, read
   `agents/repo-context-scanner.md` and run that scan yourself first.

Args: `$ARGUMENTS`.

Codex note: `.codex/hooks.json` enforces confirm-before-write for whole-file `otel-context.json`
writes (an unconfirmed `biz.*` attribute is denied). Patch-style edits are not deep-checked, so
always present business attributes for explicit confirmation and write `"confirmed": true` only
on approved ones.
