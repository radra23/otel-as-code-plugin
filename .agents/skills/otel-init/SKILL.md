---
name: otel-init
description: First-run setup for otel-as-code — scan the repo, detect service boundaries, and prime the context cache. Use before other otel-* workflows.
---

# otel-init (Codex bridge)

Follow the canonical procedure in this repo — it is the single source of truth:

1. Read `commands/otel-init.md` (repo root) and execute its steps.
2. Codex has no subagent dispatch: where it says to run the `repo-context-scanner` agent, read
   `agents/repo-context-scanner.md` and perform that read-only scan yourself.
3. For any service-identity conflicts, apply `skills/business-attr-ux/SKILL.md`.

Args: `$ARGUMENTS`.

Codex note: business attributes and inferred values are ALWAYS confirmed with the user before
writing (the plugin's confirm-before-write hook does not auto-fire here).
