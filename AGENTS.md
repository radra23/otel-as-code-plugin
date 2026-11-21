# AGENTS.md — otel-as-code

Cross-agent instructions for this repo, read by Codex, GitHub Copilot CLI and other agents that
honor `AGENTS.md`. Claude Code plugin-development specifics live in `.claude/CLAUDE.md`.

<!-- Maintainer note: Codex loads this file up to `project_doc_max_bytes` (32 KiB default) —
     keep it lean. An `AGENTS.override.md` beside it, if present, takes precedence. -->

## What this is
otel-as-code sets OpenTelemetry up for a developer who does not do observability: the output is
checked as it is written (write guard, semconv lint) and proven in CI, and the first trace shows
on their own machine the same day. It instruments a codebase (Node.js, Python, Java, .NET, Go,
Ruby, Rust, PHP), tracks the user's own functions and business numbers, writes a test that fails
when the telemetry goes missing, infers service identity from the repo, and generates
vendor-neutral Terraform for Grafana / Datadog / New Relic / Dash0. It ships as a Claude Code
plugin, as a GitHub Copilot CLI plugin and as Codex skills (which checks run in which agent, and
what proves it: README "Which agents it works in"). When you describe it to a user, use their words (tracing, slow
requests, dashboards) before OpenTelemetry's.

## Using with Codex
Capabilities are exposed as Codex skills under `.agents/skills/`, discovered when this repo is
the working directory / repo root (or vendored into one). Invoke a workflow explicitly with
`$name`. Each skill is a thin bridge — it points at the canonical procedure in `commands/`,
`skills/`, and `agents/` (the single source of truth), which you read and follow.

All `commands/…`, `skills/…/SKILL.md`, and `agents/…` paths in these skills are relative to the
otel-as-code repo root (the directory containing `.agents/` and `.codex/`). Codex integration
assumes **otel-as-code is the repo you run Codex in** — that root is the git root — so from any
subdirectory of it, `git rev-parse --show-toplevel` resolves these paths. If otel-as-code is
instead checked out *inside* a different host repo, `show-toplevel` returns the host root (not
here), so resolve these paths against otel-as-code's own checkout directory, not the git root.

- Workflows: `$otel-init`, `$otel-instrument`, `$otel-uninstrument`, `$otel-evaluate`,
  `$otel-collector`, `$otel-business-attrs`, `$otel-backend`, `$otel-remediate`, `$otel-local`,
  `$otel-enrich`, `$otel-test`.
- `$semconv-discipline` — OTel semantic-convention rules (also invoked implicitly when editing
  OTel code).

### Codex differences to respect
- **No subagent dispatch.** Where a `commands/otel-*.md` says "dispatch the `<x>` agent", read
  `agents/<x>.md` and do that work inline yourself.
- **Hooks DO run in Codex.** `.codex/hooks.json` ports the guardrails to Codex's
  `PreToolUse`/`PostToolUse` hooks (matching `apply_patch`/file edits) via thin adapters in
  `hooks/codex/` that reuse the same `hooks/*.sh` logic:
  - `write-guard` → PreToolUse: **denies** overwriting an existing generated bootstrap
    (`tracing.*` / `telemetry.*` / `opentelemetry.*` for any supported extension, plus
    `otel-java.env` and `otelcol-*.yaml` — the set is derived in `hooks/otel-paths.sh`) or an
    `infra/observability/<vendor>/*.tf`. A denial means regenerate deliberately.
    `apply_patch` reports paths relative to the session cwd; the guard normalises them before
    matching the `.claude/.otel-force` sentinel, so a relative entry there is honoured.
  - confirm-before-write → PreToolUse: **denies** writing an `otel-context.json` that carries an
    unconfirmed business attribute. A direct Edit/Write is checked like in Claude Code. An
    `apply_patch` may change the cache only as one full-file `*** Add File:` of it, which is
    checked; an Update, Move or Delete of the cache is denied, because a diff can't be checked
    before it lands. Write the cache with `scripts/write_context.py`, as the commands do. After a
    patch lands, the cache is checked again on disk. Still present business attributes for
    explicit confirmation. Present
    them already namespaced (`com.myorg.*`); a bare `biz.*` name is a placeholder, never written.
  - `semconv-lint` → PostToolUse: surfaces semconv warnings on OTel file writes (advisory).
  They load only when Codex runs with **otel-as-code as the git/project root**: Codex discovers
  `.codex/hooks.json` at the project root, and the hook commands resolve the adapters from
  `git rev-parse --show-toplevel` (Codex's recommended anchor for repo-local hooks — there is no
  per-hook config-dir variable; only Codex *plugins* get `PLUGIN_ROOT`, which this bridge is not).
  Both conditions hold only when otel-as-code is that root, so when it is vendored *inside* another
  repo the Codex hooks do not load — a Codex platform constraint, not something the config can work
  around. The Claude Code hooks (`hooks/hooks.json`, resolved via `${CLAUDE_PLUGIN_ROOT}`) are
  unaffected and remain the guardrail in that setup. SessionEnd/`session-summary` is not ported —
  Codex has SessionEnd, but its PR-changelog output has no natural Codex surface.

### GitHub Copilot CLI
Install: `copilot plugin marketplace add radra23/otel-as-code-plugin`, then
`copilot plugin install otel-as-code@otel-as-code` (marketplace and plugin are both named
`otel-as-code` in `.claude-plugin/marketplace.json`). The skills are expected to load with the
plugin; no test here proves it. Its hooks come from the
root-level `hooks.json` (Copilot's flat format, camelCase `preToolUse`/`postToolUse`), which
Copilot reads in place of `hooks/hooks.json` and Claude Code does not read at all, so each host
runs the guardrails once. The adapters in `hooks/copilot/` map Copilot's `create`/`edit` tools
to the Write/Edit payload `hooks/*.sh` read, run the scripts in the user's repo (the payload's
`cwd`; the hook process itself starts in the plugin's install folder) and answer in the JSON
Copilot acts on: `permissionDecision: "deny"` for a write-guard block (Copilot 1.0.56 does not
deny on exit 2) and `additionalContext` for lint findings (stderr never reaches the model).
Measured payloads and the reasons are in `docs/agents/copilot-spike.md` and
`tests/hooks/fixtures/copilot/`. Unlike Codex, the hooks load wherever the plugin is installed,
not only when this repo is the project root. Not ported: SessionEnd (Copilot discards its
output), and any write tool other than `create`/`edit`, which passes unchecked.
- **Subagent dispatch: not tested.** Where a `commands/otel-*.md` says "dispatch the `<x>`
  agent" and you can't, read `agents/<x>.md` and do that work inline, as in Codex.
- **VS Code: not tested.** GitHub's docs say Copilot in VS Code shares the CLI's hooks, but the
  CLI already differed from those docs (exit 2 did not deny; Claude-format `PreToolUse` never
  ran), so don't assume VS Code matches until it is run.

## Conventions & architecture
Tool-agnostic conventions — the single-sourced `SEMCONV_VERSION`, the `backends.txt` vendor list,
and the Terraform snapshot layout — plus Claude Code plugin architecture (auto-discovery,
`hooks/hooks.json`, `claude plugin validate`) live in `.claude/CLAUDE.md`. Read its "Conventions" section;
they are not restated here, to keep a single source.
