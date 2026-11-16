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
- Read stdin JSON keys `tool_name` and `tool_input.file_path` (NOT `tool`/`input`). Parse with `python3`, not `jq`. The "which Python actually runs" probe lives once, in `hooks/otel-python.sh`, sourced by write-guard and semconv-lint; the protected Terraform names live in `hooks/otel-paths.sh` (`OTEL_TF_MODULE_NAMES`).
- `--force` reaches the write-guard via a path-scoped `.claude/.otel-force` sentinel (a slash-command flag can't set env for the hook process). Sentinel entries are matched by `hooks/otel-force-match.py`, which normalises BOTH sides (Windows drive letters/backslashes ↔ Git Bash `/c/…`, relative ↔ absolute, `.`/`..`) — never compare these paths as raw strings, a `grep -Fxq` can't match across host conventions and silently turns `--force` into a no-op.
- `hooks/otel-paths.sh` is the single source of truth for which files the plugin generates (stems × extensions + fixed names); `write-guard.sh` and `session-summary.sh` both source it. Add a language or extension there, never in a per-hook list — parallel hand-kept lists are how `telemetry.ts` shipped unguarded.
- semconv-lint is advisory by default (exit 0); **strict mode** hard-blocks (exit 2) on *severe* violations only — service.*-as-span-attr + deprecated http.method/http.url/http.status_code/deployment.environment (Rules 1-4 + 4b, exact deterministic literal matches); heuristic/judgment rules (5-8) stay warn-only, including Rule 8 (a high-cardinality identifier used as a metric-instrument dimension) — CONCEPTUALLY the worst-severity finding this hook can make, per semconv-discipline's cardinality-position ranking, but its detection is a same-file window heuristic that can't bind an `.Add()`/`.Record()` call to the specific instrument a constructor created, only to "some constructor exists somewhere in this file" — a real false positive was found and fixed post-merge, so it doesn't clear the bar strict-mode blocking requires. Opt in via `OTEL_STRICT=1` (env, e.g. CI) or a `.claude/.otel-strict` sentinel (same dual pattern as `--force`). Codex PostToolUse can't deny, so its adapter reframes the block as a must-fix `additionalContext`. The hook gates on file *content* referencing an OTel API (not filename — a basename-only gate skipped application code entirely, #138), and its attribute-setter matching is language-aware across all eight supported languages, not just the JS/Java `setAttribute(` spelling.
- Tests: `bash tests/hooks/<name>.test.sh`; feed the REAL payload (`tool_name`/`tool_input`); wire every new test into the `lint-hooks` job in `.github/workflows/ci.yml`.

## Conventions
- **Subagents have no `Skill` tool** and cannot read a skill by name (skills live in the plugin cache, off the target repo, with a path the agent doesn't know). A command that dispatches a subagent MUST hand it the guidance as explicit inputs — a value (e.g. `semconvVersion`) and/or an absolute `SKILL.md` path the subagent `Read`s (`semconvGuidancePath`, `languageMaturityPath`, `terraformPatternsPath`, resolved via `${CLAUDE_PLUGIN_ROOT}`). NEVER write "read the `otel-as-code:<skill>` skill" in an agent file — it silently fails (the scanner then stamped `guidanceVersion: null`, the auditor a remembered `1.27.0`). Only the main agent running a command has `Skill`.
- `SEMCONV_VERSION` in `skills/semconv-discipline/SKILL.md` is the single source of truth; the lint hook greps it and generators stamp `<SEMCONV_VERSION>`. Don't hardcode the version elsewhere. It is the **spec** version — the SDK/semconv *packages* version independently, so never derive one from the other, and never let generated comments assert which constants a package exports (verify against the installed package or say nothing).
- `agents/repo-context-scanner.md` owns the context-JSON schema AND the cache ownership contract (scanner-owned vs user-owned fields). Commands must pass the existing cache as `priorContext` so a refresh MERGES — a bare re-scan silently destroys confirmed business attributes. Don't restate the schema in another file; point at the scanner.
- Cache freshness is keyed to the identity-input fingerprint defined in `/otel-init` Step 1, not to `HEAD`. Other commands reference that step rather than re-deriving a rule.
- `language` ≠ `runtime`. `/otel-instrument` selects a *service* filtered by `instrumentable`, never `services[0]`; a browser SPA is `language: nodejs`, `runtime: browser`, and must be refused with a reason rather than emitted for.
- **Optional external sources: detect, enrich, degrade — never require.** An MCP server or hosted service may sharpen what this plugin does (a Terraform registry lookup verifying provider schemas in `terraform-gen`; the upstream semconv registry checking the OLD→NEW table in `drift_check.py`), but it is never a dependency. Three rules: the offline path must keep working unchanged (CI validates golden snapshots with no network and no vendor auth); an unavailable source is reported as "not checked", never as a finding — a broken checker must not read as broken guidance or wrong code; and never claim verification that did not happen, so generated output states which source it was verified against, or says it was not. Vendor MCPs are runtime/query tools against a live account; this plugin generates committed artifacts before one exists. Use them to verify and validate, never to generate — routing generation through a vendor re-introduces the lock-in that vendor-neutral OTel output exists to avoid.
- `backends.txt` (repo root) is the single source of truth for the supported vendor list; the CI `validate-terraform` loop, `tests/check-snapshots.sh`, `hooks/session-summary.sh`, and `/otel-backend` validation all read it. Don't hardcode the vendor list elsewhere (per-vendor content in `terraform-patterns.md`/`terraform-gen.md` is fine).
- Terraform golden snapshots: `tests/snapshots/<vendor>/main.tf.snap`, self-contained (inline `variable` blocks) so CI validates `main.tf` standalone. `terraform` isn't installed — download a pinned binary to validate; introspect unfamiliar providers with `terraform providers schema -json`.
- `scripts/drift_check.py` (weekly `drift-check` CI job; also `workflow_dispatch`) reports when the pinned semconv / OTel-SDK / TF-provider versions fall behind upstream — informational, never fails CI (`tests/drift-check.test.sh` keeps its pin parsers honest offline). When it flags drift: bump the pins, regenerate the affected snapshots, re-validate. Exception: a NuGet row marked **drops <tfm>** (#229) is not a bump target — that release has no asset for the golden `.csproj`'s TargetFramework (`net10.0` since #229; .NET 8/9 left support 2026-11-10), and NuGet's silent `.NETStandard` fallback compiles but exports nothing over OTLP/gRPC. The .NET pins move only together with the golden TargetFramework, re-proven by the live e2e trace-flow job (a clean `dotnet build` is not evidence; `tests/e2e/dotnet-placement.sh` fails on the SDK's "doesn't support net" warning for the same reason), and the generator prints `--version`-pinned 1.20.x lines for a `net8.0`/`net9.0` project rather than the bare form.

- `/otel-enrich` is the only command that edits code a person wrote, and `scripts/enrich.py` is the
  only thing that makes or removes those edits. Its edits are INSERT-ONLY: new lines between
  `otel-as-code: enrich begin/end <id>` markers, never a changed line, so removal deletes the blocks
  and needs no record of the original (enrichment is committed and outlives any local state file;
  `.claude/` is gitignored). Keep it that way: a shape that can't be wrapped by adding lines is
  refused, not rewritten. It writes plain OpenTelemetry API calls, no helper file, so there is no new
  generated filename for `hooks/otel-paths.sh`. Every new shape or language gets a case in
  `tests/enrich.test.sh` that RUNS the enriched code against the stub API, and a span assertion in
  `tests/e2e/enrich.sh`. `enrich.py metric` emits only a name that is a confirmed counter, histogram
  or gauge in the cache (kind and unit come from there, never from an argument), and adds no metric
  attributes. The Grafana golden's business panels are proven by running their OWN queries, read out
  of the `.snap`, against the local stack in that e2e: change a business-panel query shape in
  `terraform-patterns` and the golden together, and let that job say whether Prometheus agrees.
- `/otel-enrich --clients` keeps to one client span per call. `scripts/client-coverage.json` is the
  single source of truth for which instrumentation package covers which database or queue client,
  and `tests/client-coverage.test.sh` checks every row against the published packages (network, so
  it runs in the `enrich-clients` job): add a row only with that test passing, and never treat a
  client that is not listed as "no package exists" (it is "not checked"). A client a package covers
  is refused a hand-made span; a driver under an instrumented ORM is left alone (both measured:
  SQLAlchemy plus the sqlite3 package gives two client spans per query). `enrich.py client` is the
  one place the plugin edits its own generated bootstrap after writing it, as a marked block at the
  end of the file; `/otel-instrument` drops that block on a regeneration and says so.
  `tests/e2e/enrich-clients.sh` counts client spans on the console exporter, with no Docker.
- `/otel-test` writes a telemetry test into the user's service (`otel.test.cjs`, `test_otel.py`;
  the names live in `hooks/otel-paths.sh` as `otel_test_globs`, apart from the bootstrap names so
  `/otel-instrument` never mistakes a test for a bootstrap). `scripts/telemetry_test.py` renders it
  from a spec and checks every spec value before it reaches the generated code; the command never
  writes the test by hand and never hands one over that it has not seen pass. The two languages
  capture differently on purpose: Python uses the SDK's in-memory exporter in process; Node.js
  starts the service as a child process and receives OTLP/JSON on loopback, because NodeSDK takes
  over the global provider (an in-memory provider registered before or after it captured nothing)
  and the SDK's test classes were renamed between releases while the wire format is stable. A
  change to either template is proven in `tests/e2e/telemetry-test.sh`, which runs the generated
  tests on real apps and requires them to FAIL, naming the gap, when instrumentation is removed.
  FastAPI 0.142.0 and later makes its own request span whenever a provider is registered, so
  "the request's span is missing" cannot prove the bootstrap is loaded there: the Python test
  checks the import.
- FastAPI's own telemetry (#300): from 0.142.0 FastAPI reports request spans and
  `http.server.request.duration` under the stable names, and switches itself off when the
  instrumentation package's middleware is in its stack, so there are never two server spans. The
  package reports the OLD names unless `OTEL_SEMCONV_STABILITY_OPT_IN` is set, so the Python
  bootstrap's `instrument_fastapi()` calls it only where `fastapi.telemetry` cannot be imported
  (decided at start-up, not from the declared version range; `OTEL_AS_CODE_FASTAPI_SOURCE=package`
  forces the package). `tests/e2e/fastapi-native.sh` (no Docker) holds exactly one server span per
  request on FastAPI 0.141.1 and on the current release, and the stable names by default on the
  latter. The console span exporter prints no scope: that test tells the source by child spans.

- Runtime metrics (#277) ride the Metrics signal: Node.js and Java emit them already (bundle,
  agent), Python, Go and .NET get one block in the bootstrap, and Ruby, Rust and PHP have no
  stable source, so none is generated. The per-language table, with how settled each metric
  NAME is in the semantic conventions, lives in `skills/language-maturity` ("Runtime metrics");
  re-read the registry's `model/<area>/metrics.yaml` at the new tag whenever `SEMCONV_VERSION`
  moves. Process and runtime only: never turn on host-wide `system.*` metrics from a bootstrap.
  The trace-flow e2e asserts one runtime metric per language from the Collector's `file/metrics`
  exporter (`tests/e2e/assert-metrics.sh`); it runs in Docker, so only CI proves it.
- Go pins: the golden is on OpenTelemetry Go v1.47 (Go 1.26, logs Stable, `otel.SetLoggerProvider`;
  `InitOtelLogsBeta` kept as a deprecated wrapper). v1.47 dropped Go 1.25, so a project whose
  `go.mod` declares `go 1.25` or older gets the v1.46 line by three documented substitutions
  ("Go below 1.26" in `instrumentation-gen`); `tests/snapshots/instrument/go/legacy/` holds that
  line's module files and the `go-legacy-line` CI job builds it on Go 1.25. The drift check
  compares only the current line: the legacy pins are held back on purpose, like the .NET
  `drops <tfm>` rows. Regenerate `go.mod`/`go.sum` with a real `go mod tidy` and `go build` next
  to `fixtures/go-greenfield/main.go`, never by hand.
- Go logs need two things and the bootstrap used to ship one: until 0.23.0 `InitOtelLogs` built a
  provider nothing wrote to, and the matrix called that "logs generated" because no
  test asserted a record. `tracing.go` now has `OtelSlogHandler()` (`otelslog`), and the printed
  optional wiring installs it beside the app's console handler with `slog.NewMultiHandler` (Go
  1.26; never `slog.SetDefault` from the bootstrap, never wrap `slog.Default().Handler()`, which
  deadlocks). `tests/e2e/run.sh` asserts a Go record with a trace ID
  (`assert-logs.sh --expect-trace-id`). For any language: a logs signal is proven by a record
  arriving, not by a provider compiling.
- Trace IDs in log lines (#279): the Python bootstrap's `_add_trace_ids_to_logs()` block adds
  `otelTraceID`/`otelSpanID` to every `logging` record and appends ` trace_id=... span_id=...` to
  lines the plain `logging.Formatter` renders; Node.js needs nothing generated (the bundle's pino,
  winston and bunyan instrumentations do it). Never replace the user's logger or format: the
  upstream `set_logging_format` was measured to make the app's later `basicConfig(format=...)` a
  no-op, so it is not used. Text is never appended to a custom formatter class or to a line that
  is already JSON (it was caught breaking a structlog-style formatter in a probe). The block is
  the same text in both Python goldens and the generator (`tests/log-trace-ids.test.sh`), and
  `tests/e2e/log-trace-ids.sh` (no Docker) requires the ID in the line to EQUAL the request span's
  and each untouched case to be byte-identical. The per-language table is in
  `skills/language-maturity`; a language not run there is "not checked".
- The Grafana log panel and error-log alert (#279) query Loki through `var.loki_datasource_uid`.
  Their two LogQL queries are written once, in `terraform-patterns` ("Log panel and error-log
  alert"); `tests/log-panel.test.sh` requires both Grafana goldens to carry exactly those, and
  `tests/e2e/log-panel.sh` runs them, read out of the golden, against the local stack's Loki
  (`lgtm_check.py logs`), including that the alert query returns nothing before an error is
  logged. Loki's label is `service_name` with the bare name (no `<namespace>/` prefix, unlike
  Prometheus's `job`), and severity is filtered by `severity_number >= 17`, never by text. The
  alert's query is proven, its rule evaluation is not. New Relic has a Logs page and the same
  alert on `severity.number` (New Relic's documented OTLP mapping); Dash0 has a `dash0.logs`
  volume panel and deliberately NO alert, because the severity values of that metric's label are
  not documented and a guessed filter would never fire while looking healthy. Neither is run
  against data. Datadog has nothing yet.
- The dashboard's runtime row comes from `skills/terraform-patterns/runtime-panels.json`, the one
  table of runtime panels per language (metric, kind, unit, name stability, PromQL). The generator
  reads it and never writes a runtime query from memory. Add or change a panel there only: the
  trace-flow e2e forwards metrics to a `grafana/otel-lgtm` container (the `/otel-local` image,
  same pin) and runs EVERY query in the table per language (`tests/e2e/assert-runtime-panels.sh`),
  and `tests/runtime-panels.test.sh` pins the Grafana goldens to the table byte for byte
  (regenerate the block with `tests/runtime_panels_render.py`). Pick metrics that exist without
  an event having happened: `jvm.gc.duration` (a histogram, recorded only when a collection runs)
  failed the job on a run where the JVM had not collected yet and was replaced by
  `jvm.memory.used_after_last_gc`. Node.js's `v8js.gc.duration` panel is the same kind; it has been
  present on every run so far and is the first suspect if that job fails on a Node.js query.
  New Relic and Dash0 DERIVE their runtime queries from the same table by a fixed rule per
  backend (`terraform-patterns`; `tests/runtime_panels_render.py` renders all three and the
  goldens are pinned to it). Only the Grafana queries are run against data: for the other two,
  `terraform validate` proves the schema and, for Dash0 only, the live apply proves a real account
  accepts the dashboard (the job has never had Grafana or New Relic credentials: every run since
  2026-09-03 skipped them, so never write "applied to a real account" for those two without
  reading `gh run list --workflow tf-live-validate.yml` first); neither proves that a chart has
  data, and every derived panel says so. Datadog has no row (it renames runtime metrics on ingest,
  #121).

- `evals/routing/` measures whether a fresh session picks this plugin (`claude plugin eval` for
  only-this-plugin, `run-headless.sh` for a full personal plugin set, one scorer `score.py` for
  both). Run it before and after any command/skill `description` change; it is billed, so it is
  `workflow_dispatch` only. Don't loosen `score.py` to pass: its rules are pinned by
  `tests/routing-eval.test.sh`.

- Anthropic's plugin directory follows the `directory` branch, a slim build of `main` that
  `.github/workflows/directory-branch.yml` publishes with `scripts/build-directory.sh`: only what
  the plugin uses at run time (commands, agents, skills, the Claude Code hooks, the scripts named
  through `${CLAUDE_PLUGIN_ROOT}`, `backends.txt`, README, LICENSE). A new file a command or hook
  reaches through `${CLAUDE_PLUGIN_ROOT}` must be added to the build script; `tests/directory-build.test.sh`
  fails if it is missing. Hooks must name every program they run (literal `python3`/`python`, paths
  from `${CLAUDE_PLUGIN_ROOT}`): the directory blocks a hook whose program is computed. It also
  blocked an inline `py -c` that normalised a path (0.11.5, "Command path can't be followed"), while
  the same logic in a file run as `py "${CLAUDE_PLUGIN_ROOT}/hooks/<file>.py" ...` passes: put new
  hook logic in a plugin file, and check a preview of the slim build in the portal before any
  resubmission. Since 0.11.8 the build does not pass that check (write-guard's no-Python branch reads
  the file name with plain shell, which the portal's static check can't follow); that was accepted
  because the directory refuses the plugin by policy anyway, and must be revisited before submitting.
  The 0.11.7 submission was then refused by policy: from a non-Verified organization the directory
  accepts no command hooks and no scripts (only Markdown, text, JSON, YAML, images), so the plugin
  is not listed there; it ships through its own marketplace (see docs/listing/plugin-directory.md).

## Shell
- GitHub Actions runs `run:` blocks as `bash -eo pipefail`; reproduce CI shell logic with that, not the local zsh (zsh doesn't word-split unquoted `$VAR` — use literal args/arrays).
