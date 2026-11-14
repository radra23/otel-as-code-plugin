---
name: otel-local
description: See this service's traces, logs and metrics on your machine. Starts a free local Grafana stack (grafana/otel-lgtm) in Docker and points the service at it. Not for diagnosing one slow or failing request.
---

# otel-local (Codex bridge)

> **Requires the otel-as-code repo.** The `commands/` / `skills/` / `agents/` files referenced below live there. If they're not present in your workspace, stop and tell the user to add the repo (see AGENTS.md).

Follow the canonical procedure in this repo, which is the single source of truth:

1. Read `commands/otel-local.md` (repo root) and execute its steps.
2. Where it runs `${CLAUDE_PLUGIN_ROOT}/scripts/lgtm_check.py`, run `scripts/lgtm_check.py` from
   this repo instead.

Args: `$ARGUMENTS` (e.g. `--service <id>`, `--force`, `--dry-run`, `--down`).

Codex note: `.codex/hooks.json` enforces write-guard here, so a denied overwrite of an existing
`otel-local.compose.yaml` / `otel-local.env` means regenerate deliberately with `--force`.
