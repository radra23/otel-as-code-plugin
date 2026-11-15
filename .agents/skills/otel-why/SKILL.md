---
name: otel-why
description: Find out why part of a running app is slow, times out, fails only sometimes, or spikes. Adds a few timing spans around the suspect code, runs it against a local trace viewer on this machine, and explains the cause from the measured evidence. Use when the user describes a speed or reliability symptom in plain words ("checkout is slow", "login times out sometimes"). Not for a test that fails every time, a crash with a stack trace, or a slow build.
---

# otel-why (Codex bridge)

> **Requires the otel-as-code repo.** The `commands/` / `skills/` / `agents/` files referenced below live there. If they're not present in your workspace, stop and tell the user to add the repo (see AGENTS.md).

Follow the canonical procedure in this repo, which is the single source of truth:

1. Read `commands/otel-why.md` (repo root) and execute its steps, with the user's symptom as the
   argument.
2. Where it runs `/otel-instrument` or `/otel-local`, follow `commands/otel-instrument.md` and
   `commands/otel-local.md` the same way.
3. Where it runs `${CLAUDE_PLUGIN_ROOT}/scripts/probes.py`, `trace_summary.py` or
   `lgtm_check.py`, run them from this repo's `scripts/` instead.

Args: `$ARGUMENTS` (e.g. `"checkout is slow" --route "POST /checkout"`).

Codex note: probes are edits to the user's code, applied by `scripts/probes.py` from the shell,
so `.codex/hooks.json` does not see them; remove them with `$otel-uninstrument --probes`, which
restores the recorded originals.
