---
name: otel-test
description: Generate a test that fails when a service's telemetry goes missing. It sends one request through the service and asserts the request's span, the spans otel-enrich added and the confirmed business metrics all came out, with no backend. Node.js and Python services that otel-instrument has already set up. Use when asked to test instrumentation, protect telemetry from regressions, or check spans and metrics in CI.
---

# otel-test (Codex bridge)

> **Requires the otel-as-code repo.** The `commands/` / `skills/` / `agents/` files referenced below live there. If they're not present in your workspace, stop and tell the user to add the repo (see AGENTS.md).

Follow the canonical procedure in this repo, which is the single source of truth:

1. Read `commands/otel-test.md` (repo root) and execute its steps.
2. Where it runs `${CLAUDE_PLUGIN_ROOT}/scripts/telemetry_test.py` or `enrich.py`, run them from
   this repo's `scripts/` instead.
3. Codex has no subagent dispatch: if the context cache is stale or absent, read
   `agents/repo-context-scanner.md` and run that scan inline first (Step 1).

The one thing that must not go wrong: **the test file is rendered by `scripts/telemetry_test.py`
from a spec, and is handed over only after you have run it and seen it pass.** Never write the
test with `apply_patch` yourself, and never delete an expectation to make a failing test green.

Args: `$ARGUMENTS` (e.g. `--service checkout-api`, `--route "POST /checkout"`, `--dry-run`, `--force`).
