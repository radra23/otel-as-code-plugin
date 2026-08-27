---
name: otel-init
description: First-run setup for otel-as-code — scan the repo, detect service boundaries, and prime the context cache. Use before other otel-* workflows.
---

# otel-init (Codex bridge)

> **Requires the otel-as-code repo.** The `commands/` / `skills/` / `agents/` files referenced below live there — if they're not present in your workspace, stop and tell the user to add the repo (see AGENTS.md).

Follow the canonical procedure in this repo — it is the single source of truth:

1. Read `commands/otel-init.md` (repo root) and execute its steps.
2. Codex has no subagent dispatch: where it says to run the `repo-context-scanner` agent, read
   `agents/repo-context-scanner.md` and perform that read-only scan yourself.
3. For any service-identity conflicts, apply `skills/business-attr-ux/SKILL.md`.

Args: `$ARGUMENTS`.

Codex note: `.codex/hooks.json` enforces confirm-before-write on whole-file `otel-context.json`
writes; still confirm all inferred business attributes with the user before writing.
