---
description: Propose a deployment-config diff for a service /otel-instrument can't bootstrap (generatorSupported:false, inScope:true)
argument-hint: "[--service <id>]"
---

# /otel-remediate [--service <id>]

Propose a deployment-config diff — env vars / manifest fields — for a service with real native
OpenTelemetry support but no application source `/otel-instrument` can bootstrap: a third-party
binary or container image (v1: Keycloak only — see `deployment-remediation/SKILL.md`). Read-only:
prints a diff, never writes it. This is the counterpart to `/otel-instrument --fix <ids>` for the
services that command explicitly refuses (`generatorSupported: false`).

## Flags
- `--service <id>` — the service to remediate, by `id` from the context JSON. Skips the Step 2
  prompt.

## Step 1: Load context

Check `.claude/otel-context.json`. Apply the freshness rule from `/otel-init` Step 1
(identity-input fingerprint, not `HEAD`). If stale or absent, dispatch
`otel-as-code:repo-context-scanner` **passing the existing cache as `priorContext`** and write
what it returns — a refresh is a merge, never a replace (see `agents/repo-context-scanner.md`).

## Step 2: Select the target SERVICE

This command's candidate set is the **complement** of `/otel-instrument`'s: services
`/otel-instrument` explicitly refuses, not the ones it can bootstrap.

1. Build the candidate list: every service in `context.services` with `generatorSupported: false`
   AND `inScope: true`. If `--service <id>` was given, use exactly that one (and validate it
   below) rather than building the list.
2. Then:
   - **Exactly one candidate** → use it. Print: "Target: <name> (<rootDir>, <host>)".
   - **More than one** → list them and ask, same pattern as `/otel-instrument` Step 2:
     ```
     Which service should be remediated?
       1  keycloak       infra/keycloak/   kubernetes   (quay.io/keycloak/keycloak:26.7.0)
       2  redis          infra/redis/      container    (redis:7-alpine)
     →
     ```
   - **No candidates** → print why, then exit without writing anything:
     ```
     ⚠ No service in this repo is a candidate for /otel-remediate.
       Every generatorSupported:false service is either out of scope (browser/RUM) or
       /otel-instrument already covers every in-scope service directly.
     ```
3. Validate the chosen service. If `generatorSupported` is `true`, refuse — this is
   `/otel-instrument`'s service, not this command's:
   ```
   ⚠ <name> has generatorSupported:true — use /otel-instrument for it, not /otel-remediate.
   ```
   If `inScope` is `false`, refuse with the same reason the scanner recorded
   (`instrumentableReason`) — a browser bundle, for instance, is out of scope for either command.

## Step 3: Read the service's deployment config

Read every file in `service.deployment.configFiles`. If that list is empty, there is nothing to
propose changes against — print so and exit:

```
⚠ <name>: service.deployment.configFiles is empty — no Kubernetes manifest, docker-compose file,
  or Dockerfile on record for this service. Re-run /otel-init if one exists but wasn't detected.
```

## Step 4: Dispatch deployment-remediation-gen

Pass to `otel-as-code:deployment-remediation-gen`:
- `context`: the loaded context JSON
- `service`: the selected service object from Step 2
- `deploymentRemediationPath`: `${CLAUDE_PLUGIN_ROOT}/skills/deployment-remediation/SKILL.md` —
  the subagent has no `Skill` tool and `Read`s this for the known-targets table and the verified
  Keycloak env var list
- `configFiles`: the paths and content read in Step 3

## Step 5: Display the report

Print the report returned by the subagent verbatim. It is print-only by design — see the
`deployment-remediation` skill's "What this is not" section for why this command never writes
the proposed diff itself, unlike `/otel-instrument`. Do not add an `--apply` flag or any other
write path without treating that as its own deliberate decision, not a default extension of this
command.
