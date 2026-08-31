---
name: otel-evaluate
description: Read-only brownfield audit of existing OTel coverage — missing signals, semconv conformance, and cardinality risks. Use to assess a codebase's current instrumentation.
---

# otel-evaluate (Codex bridge)

> **Requires the otel-as-code repo.** The `commands/` / `skills/` / `agents/` files referenced below live there — if they're not present in your workspace, stop and tell the user to add the repo (see AGENTS.md).

Follow the canonical procedure in this repo — it is the single source of truth:

1. Read `commands/otel-evaluate.md` (repo root) and execute its steps.
2. Codex has no subagent dispatch: where it says to run the `brownfield-auditor` agent, read
   `agents/brownfield-auditor.md` and perform that read-only gap analysis yourself.
3. Judge conformance against `skills/semconv-discipline/SKILL.md`.

Args: `$ARGUMENTS`.

This workflow is read-only — it produces an audit report and never rewrites instrumentation.
Two things to get right: read the files named in `existingOtel.bootstrapFiles` (`sdkPackages`
holds npm/PyPI specifiers, not paths), and treat the cache's `derived` judgements as claims to
re-verify against source rather than findings to repeat. When offering next steps, say plainly
that `--force` is a full regeneration that discards hand edits, and prefer `--fix <ids>`.
