# otel-as-code — Claude Code plugin

This repo IS a Claude Code plugin (commands / skills / subagents / hooks), not an app.
Components are declared as inline arrays in `.claude-plugin/plugin.json`; the referenced
`.md` files need NO YAML frontmatter.

## Hooks (`hooks/*.sh`)
- Read stdin JSON keys `tool_name` and `tool_input.file_path` (NOT `tool`/`input`). Parse with `python3`, not `jq`.
- `--force` reaches the write-guard via a path-scoped `.claude/.otel-force` sentinel (a slash-command flag can't set env for the hook process).
- Tests: `bash tests/hooks/<name>.test.sh`; feed the REAL payload (`tool_name`/`tool_input`); wire every new test into the `lint-hooks` job in `.github/workflows/ci.yml`.

## Conventions
- `SEMCONV_VERSION` in `skills/semconv-discipline.md` is the single source of truth; the lint hook greps it and generators stamp `<SEMCONV_VERSION>`. Don't hardcode the version elsewhere.
- `backends.txt` (repo root) is the single source of truth for the supported vendor list; the CI `validate-terraform` loop, `tests/check-snapshots.sh`, `hooks/session-summary.sh`, and `/otel-backend` validation all read it. Don't hardcode the vendor list elsewhere (per-vendor content in `terraform-patterns.md`/`terraform-gen.md` is fine).
- Terraform golden snapshots: `tests/snapshots/<vendor>/main.tf.snap`, self-contained (inline `variable` blocks) so CI validates `main.tf` standalone. `terraform` isn't installed — download a pinned binary to validate; introspect unfamiliar providers with `terraform providers schema -json`.

## Shell
- GitHub Actions runs `run:` blocks as `bash -eo pipefail`; reproduce CI shell logic with that, not the local zsh (zsh doesn't word-split unquoted `$VAR` — use literal args/arrays).
