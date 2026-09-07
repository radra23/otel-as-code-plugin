---
name: otel-remediate
description: Propose a deployment-config diff (env vars / manifest fields) for a service with no application source to bootstrap but real native OTel support — e.g. a Keycloak deployment. Use for generatorSupported:false, inScope:true services that /otel-instrument refuses.
---

# otel-remediate (Codex bridge)

> **Requires the otel-as-code repo.** The `commands/` / `skills/` / `agents/` files referenced below live there — if they're not present in your workspace, stop and tell the user to add the repo (see AGENTS.md).

Follow the canonical procedure in this repo — it is the single source of truth:

1. Read `commands/otel-remediate.md` (repo root) and execute its steps.
2. Codex has no subagent dispatch: where it says to run the `deployment-remediation-gen` agent,
   read `agents/deployment-remediation-gen.md` and perform that read-only diff-proposal yourself.
3. Read `skills/deployment-remediation/SKILL.md` for the known-targets table (v1: Keycloak only)
   and the verified env var list — do not guess at another binary's config surface by analogy.

Args: `$ARGUMENTS`.

This workflow is print-only by design — it proposes a unified diff against the service's
deployment manifest(s) and never writes it. Refuse plainly for any target not in the skill's
known-targets table rather than guessing.
