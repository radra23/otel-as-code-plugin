---
name: validate-plugin
description: Run the local validation suite for the otel-as-code plugin before committing or opening a PR — hook tests, fixture integrity, plugin.json manifest checks, shell syntax, and terraform-validate on every committed snapshot. Covers the GitHub Actions CI checks plus extra local-only sanity.
disable-model-invocation: true
---

# Validate the otel-as-code plugin

Run the project's CI checks locally (plus a couple of local-only sanity checks) and report a concise PASS/FAIL per group plus an overall verdict. On failure, show the failing command's output.

## 1. Hook tests (CI: lint-hooks)
Iterate every suite under `tests/hooks/` — do NOT hardcode the list, so new tests run automatically:
```bash
for t in tests/hooks/*.test.sh; do echo "== $t =="; bash "$t" || exit 1; done
```

## 2. Fixture integrity (CI: validate-fixtures)
- **nodejs-greenfield**: `package.json`, `index.js`, `Dockerfile` exist AND `package.json` has NO `@opentelemetry` dependency.
- **python-greenfield**: `pyproject.toml`, `app.py`, `Dockerfile` exist AND `pyproject.toml` has NO `opentelemetry` dependency.
- **nodejs-brownfield**: `tracing.js` exists AND still contains the three seeded violations — `service.name` as a span attribute, `http.method`, and un-namespaced `orderId` — which the lint tests assert against.

## 3. Plugin manifest & structure (CI: validate-plugin-manifest)
- `claude plugin validate . --strict` — must pass. Validates `plugin.json` (metadata-only), `marketplace.json`, and the auto-discovered components (`commands/*.md`, `agents/*.md`, `skills/<name>/SKILL.md`, `hooks/hooks.json`).
- If the `claude` CLI isn't available: confirm both `.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json` are valid JSON, plugin.json declares NO inline component arrays, and the convention dirs/files exist.

## 4. Shell sanity (local-only — no CI equivalent)
- `bash -n` on every `hooks/*.sh` and `tests/**/*.sh`.

## 5. Terraform snapshots (CI: validate-terraform)
For each `tests/snapshots/<vendor>/main.tf.snap`:
- Copy it to a temp dir as `main.tf`, then `terraform init -backend=false -input=false` + `terraform validate`.
- `terraform` is NOT installed locally — download a pinned binary (e.g. 1.7.x from `releases.hashicorp.com`) to a temp path and use that. (CI installs it via `hashicorp/setup-terraform`.)
- Run the snapshot loop under `bash -eo pipefail` to match CI semantics (the local shell is zsh, which behaves differently on glob no-match).

## Report
One line PASS/FAIL per group (hooks / fixtures / manifest / shell / terraform) and an overall verdict. This is the gate to clear before committing.
