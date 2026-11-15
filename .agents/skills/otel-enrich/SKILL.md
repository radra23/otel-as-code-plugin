---
name: otel-enrich
description: Add telemetry inside the user's own code, either a span around one function or the business metrics they confirmed, so generated dashboards fill. An in-place edit to hand-written code, shown as a diff first, insert-only between markers, and removable exactly. Node.js and Python services that otel-instrument has already set up. Use when asked to trace or time a specific function, or to emit the confirmed business metrics.
---

# otel-enrich (Codex bridge)

> **Requires the otel-as-code repo.** The `commands/` / `skills/` / `agents/` files referenced below live there. If they're not present in your workspace, stop and tell the user to add the repo (see AGENTS.md).

Follow the canonical procedure in this repo, which is the single source of truth:

1. Read `commands/otel-enrich.md` (repo root) and execute its steps.
2. Where it runs `${CLAUDE_PLUGIN_ROOT}/scripts/enrich.py` or `lgtm_check.py`, run them from this
   repo's `scripts/` instead.
3. Codex has no subagent dispatch: if the context cache is stale or absent, read
   `agents/repo-context-scanner.md` and run that scan inline first (Step 1).

The one thing that must not go wrong: **the edit is made by `scripts/enrich.py`, after the user
has seen its diff and said yes.** Never write the span into the user's code with `apply_patch`
yourself, and never adjust the lines between the markers by hand. A shape the script refuses is
reported, not worked around.

With `--business`, follow the command's "Business metrics" section: `scripts/enrich.py metric`
for each confirmed counter, histogram or gauge, one diff and one yes per metric, then record the
`callSite` through `scripts/write_context.py`.

Args: `$ARGUMENTS` (e.g. `lib/orders.js:checkout`, `--business`, `--span-name orders.checkout`, `--dry-run`).

Codex note: the script edits files from the shell, so `.codex/hooks.json` does not see the edit;
the diff and the confirmation are the gate. Remove with `$otel-uninstrument --enrichment`.
