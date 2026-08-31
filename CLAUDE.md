# otel-as-code — Claude Code plugin

This repo IS a Claude Code plugin (commands / skills / agents / hooks), not an app.
`.claude-plugin/plugin.json` holds ONLY metadata — components are AUTO-DISCOVERED from
conventional dirs: `commands/*.md`, `agents/*.md`, `skills/<name>/SKILL.md`, `hooks/hooks.json`.
Each command needs `description` frontmatter; each agent/skill needs `name` + `description`.
`.claude-plugin/marketplace.json` makes the repo installable as its own marketplace.
Validate structure with `claude plugin validate . --strict`.

Cross-agent instructions live in `AGENTS.md` (read by Codex et al.); the same capabilities are
bridged to Codex: skills in `.agents/skills/` (thin wrappers pointing back at `commands/`,
`skills/`, `agents/`), and the guardrails in `.codex/hooks.json` (PreToolUse/PostToolUse adapters
in `hooks/codex/` that reuse `hooks/*.sh`, translating Codex's `apply_patch` payload +
`permissionDecision` contract). Keep the bridges in sync when you rename/move a command, skill,
agent, or hook — the `validate-codex-bridge` CI job checks the skill references resolve.

## Hooks (`hooks/*.sh`, registered in `hooks/hooks.json`)
- Registered in `hooks/hooks.json` (NOT inline in plugin.json): PreToolUse/PostToolUse matcher `Write|Edit` → write-guard / semconv-lint; SessionEnd → session-summary; each invoked as `bash "${CLAUDE_PLUGIN_ROOT}/hooks/<name>.sh"`.
- Read stdin JSON keys `tool_name` and `tool_input.file_path` (NOT `tool`/`input`). Parse with `python3`, not `jq`.
- `--force` reaches the write-guard via a path-scoped `.claude/.otel-force` sentinel (a slash-command flag can't set env for the hook process). Sentinel entries are matched by `hooks/otel-force-match.py`, which normalises BOTH sides (Windows drive letters/backslashes ↔ Git Bash `/c/…`, relative ↔ absolute, `.`/`..`) — never compare these paths as raw strings, a `grep -Fxq` can't match across host conventions and silently turns `--force` into a no-op.
- `hooks/otel-paths.sh` is the single source of truth for which files the plugin generates (stems × extensions + fixed names); `write-guard.sh` and `session-summary.sh` both source it. Add a language or extension there, never in a per-hook list — parallel hand-kept lists are how `telemetry.ts` shipped unguarded.
- semconv-lint is advisory by default (exit 0); **strict mode** hard-blocks (exit 2) on *severe* violations only — service.*-as-span-attr + deprecated http.method/http.url/http.status_code (Rules 1-4); heuristic/judgment rules (5-7) stay warn-only. Opt in via `OTEL_STRICT=1` (env, e.g. CI) or a `.claude/.otel-strict` sentinel (same dual pattern as `--force`). Codex PostToolUse can't deny, so its adapter reframes the block as a must-fix `additionalContext`.
- Tests: `bash tests/hooks/<name>.test.sh`; feed the REAL payload (`tool_name`/`tool_input`); wire every new test into the `lint-hooks` job in `.github/workflows/ci.yml`.

## Conventions
- `SEMCONV_VERSION` in `skills/semconv-discipline/SKILL.md` is the single source of truth; the lint hook greps it and generators stamp `<SEMCONV_VERSION>`. Don't hardcode the version elsewhere. It is the **spec** version — the SDK/semconv *packages* version independently, so never derive one from the other, and never let generated comments assert which constants a package exports (verify against the installed package or say nothing).
- `agents/repo-context-scanner.md` owns the context-JSON schema AND the cache ownership contract (scanner-owned vs user-owned fields). Commands must pass the existing cache as `priorContext` so a refresh MERGES — a bare re-scan silently destroys confirmed business attributes. Don't restate the schema in another file; point at the scanner.
- Cache freshness is keyed to the identity-input fingerprint defined in `/otel-init` Step 1, not to `HEAD`. Other commands reference that step rather than re-deriving a rule.
- `language` ≠ `runtime`. `/otel-instrument` selects a *service* filtered by `instrumentable`, never `services[0]`; a browser SPA is `language: nodejs`, `runtime: browser`, and must be refused with a reason rather than emitted for.
- `backends.txt` (repo root) is the single source of truth for the supported vendor list; the CI `validate-terraform` loop, `tests/check-snapshots.sh`, `hooks/session-summary.sh`, and `/otel-backend` validation all read it. Don't hardcode the vendor list elsewhere (per-vendor content in `terraform-patterns.md`/`terraform-gen.md` is fine).
- Terraform golden snapshots: `tests/snapshots/<vendor>/main.tf.snap`, self-contained (inline `variable` blocks) so CI validates `main.tf` standalone. `terraform` isn't installed — download a pinned binary to validate; introspect unfamiliar providers with `terraform providers schema -json`.
- `scripts/drift_check.py` (weekly `drift-check` CI job; also `workflow_dispatch`) reports when the pinned semconv / OTel-SDK / TF-provider versions fall behind upstream — informational, never fails CI (`tests/drift-check.test.sh` keeps its pin parsers honest offline). When it flags drift: bump the pins, regenerate the affected snapshots, re-validate.

## Shell
- GitHub Actions runs `run:` blocks as `bash -eo pipefail`; reproduce CI shell logic with that, not the local zsh (zsh doesn't word-split unquoted `$VAR` — use literal args/arrays).
