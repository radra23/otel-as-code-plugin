---
description: Generate Terraform for one observability backend (grafana | datadog | newrelic | dash0)
argument-hint: "<vendor> [--kind all|dashboard|alerts|slo] [--output-dir <path>] [--experimental] [--force] [--dry-run]"
---

# /otel-backend <vendor> [--kind all|dashboard|alerts|slo] [--output-dir <path>] [--experimental] [--force]

Generate a complete Terraform module for one observability backend.
Supported vendors: the backends listed in `backends.txt` at the plugin root — the single
source of truth (currently grafana, datadog, newrelic, dash0).

## Flags
- `<vendor>` — REQUIRED. Must be one of the backends listed in `backends.txt` (plugin root)
- `--kind` — default `all`. Emit only one artifact type: `dashboard`, `alerts`, or `slo`
- `--output-dir` — default `infra/observability/<vendor>/`
- `--experimental` — include pre-Stable semconv in generated resource queries
- `--force` — overwrite existing module files
- `--dry-run` — preview without writing: pass `dryRun: true` to `terraform-gen` (Step 4) so it
  returns each file as `{path, content}` instead of writing; print a unified diff of each against
  on-disk (or "would create" for a new file), write nothing, do NOT create the `.otel-force`
  sentinel, and exit non-zero if anything would change. `terraform fmt`/`validate` are skipped
  (they need files on disk)

## Step 1: Validate vendor argument

Read the supported backends from `${CLAUDE_PLUGIN_ROOT}/backends.txt` (one vendor per line —
the single source of truth). If `<vendor>` is not in that list:
- Print: "Unknown vendor: <vendor>. Supported: <the backends from backends.txt>"
- Print: "v1 will add: honeycomb, dynatrace, sumo-logic, splunk, azure-monitor,
  cloudwatch, gcp-ops, elastic, lightstep, chronosphere, last9"
- Exit.

## Step 2: Load skills and context

Read the `otel-as-code:terraform-patterns` skill — apply all backend-specific patterns.
Check `.claude/otel-context.json`. Apply the freshness rule from `/otel-init` Step 1
(identity-input fingerprint, not `HEAD`). If stale or absent, dispatch
`otel-as-code:repo-context-scanner` **passing the existing cache as `priorContext`** and write
what it returns — a refresh is a merge, never a replace (see the cache ownership contract in
`agents/repo-context-scanner.md`).

If `context.confirmedAt` is null (business attrs not confirmed):
- Print: "⚠ Business attributes have not been confirmed yet. Running /otel-business-attrs first
  will improve the generated dashboard queries and SLO targets."
- Ask: "Continue anyway? [Y/n]"
- If 'n': exit with "Run /otel-business-attrs first, then re-run /otel-backend <vendor>"

## Step 3: Check for existing module

If `<output_dir>/*.tf` files exist AND `--force` is NOT set:
- Print: "⚠ Terraform files already exist in <output_dir>. Use --force to overwrite."
- Exit.

If they exist AND `--force` IS set:
- Print which files will be regenerated from scratch and confirm before writing — `--force`
  discards hand edits to the module.
- Authorize the overwrite for the `write-guard` hook by listing the module files (`main.tf`,
  `variables.tf`, `outputs.tf`) under `<output_dir>` in the `.claude/.otel-force` sentinel, one
  per line (this is how `--force` reaches the hook). **Truncate the sentinel first** (`:>`) so a
  leftover from an aborted earlier run can never grant a standing overwrite authorization, then
  append the three module files:
  `mkdir -p .claude && :> .claude/.otel-force && for f in main.tf variables.tf outputs.tf; do printf '%s\n' "<output_dir>/$f" >> .claude/.otel-force; done`
  Repo-relative or absolute both work: the guard normalises both sides before comparing, so the
  sentinel does not have to match the host's path convention. It stays path-scoped — a file you
  do not list is still protected.

## Step 4: Dispatch terraform-gen subagent

Pass to `otel-as-code:terraform-gen`:
- `context`: loaded context JSON
- `backend`: the validated vendor string
- `terraformPatternsPath`: `${CLAUDE_PLUGIN_ROOT}/skills/terraform-patterns/SKILL.md` — the
  subagent has no `Skill` tool and `Read`s this file for the per-backend provider patterns and
  gotchas (following those from memory is how the New Relic `account_id` bug in #38 happened).
- `output_dir`: resolved output directory
- `kind`: from --kind flag (default 'all')
- `experimental`: from --experimental flag

## Step 5: Display the subagent's output

The subagent handles all file writing, `terraform fmt`, and `terraform validate`.
Print its output verbatim including the next-steps block.

If a `.claude/.otel-force` sentinel was created in Step 3, remove it now to restore the
write-guard: `rm -f .claude/.otel-force`.

After the subagent output, print:
```
Note: /otel-backend does not run terraform apply. Credentials stay in your environment.
To apply: cd <output_dir> && terraform init && terraform plan && terraform apply
```
