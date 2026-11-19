# GitHub Copilot CLI: do the guardrails run? (spike)

Tracking issue: #315. Related: #266 (positioning: "checked as it is written"), #268.

The question was never whether the skills load (Copilot already reads `.agents/skills/`). It was
whether `write-guard.sh` and `semconv-lint.sh` run, and whether what they decide reaches the
model. This page records what was read and what was measured on 2026-11-19. No hook, skill,
README or `plugin.json` was changed.

**Setup measured:** GitHub Copilot CLI 1.0.56 (the copy VS Code's Copilot Chat ships), macOS,
signed in. Model `gpt-4.1` (the account's default `claude-haiku-4.5` answered
`model_not_supported`, and the other models tried were "not available"). The plugin was installed
with `copilot plugin marketplace add <this repo>` + `copilot plugin install otel-as-code@otel-as-code`
into `~/.copilot/installed-plugins/`, and sessions ran headless (`-p`, `--output-format json`,
`--log-level debug`) in a scratch git copy of `fixtures/python-greenfield` seeded with the
marker-stamped `tests/snapshots/instrument/python/tracing.py`. Raw hook stdin was captured by
throwaway logger plugins (one per hook-file format) installed from a scratch marketplace; their
`logger.py` wrote outside the repo.

**Evidence files** (scrubbed: home paths, user name, session UUIDs; the scratch repo is `/work/fixture`)
live in [`tests/hooks/fixtures/copilot/`](../../tests/hooks/fixtures/copilot/):
the stdin of each event in each naming mode (`<event>.<mode>.<tool>.stdin.json`),
`hook-process-env.json` (cwd and environment of the hook process) and
`cli-debug-log-excerpts.txt` (the CLI's own log of which hooks ran).

**Doc sources:**
[A] https://docs.github.com/copilot/reference/hooks-reference ·
[B] https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-plugin-reference ·
[C] https://code.visualstudio.com/docs/copilot/customization/hooks ·
[D] https://code.visualstudio.com/docs/agents/reference/agent-plugin-reference

Confidence: **High** = measured and consistent with the docs, or measured more than once.
**Medium** = measured once, or documented but not measured. **Low** = inferred.
"Unverified" = docs only.

## Step 1 and 2: the questions

| # | Question | Answer | Evidence | Confidence |
|---|---|---|---|---|
| 1 | Event names accepted | Both. camelCase (`preToolUse`) and PascalCase (`PreToolUse`) both fired from the same flat file. The name chosen selects the payload format: camelCase gets Copilot's own fields, PascalCase gets snake_case "VS Code compatible" fields. | [A] "Two payload formats are supported, selected by the event name"; `preToolUse.camel.edit.stdin.json` vs `PreToolUse.pascal.edit.stdin.json` | High |
| 2a | `preToolUse` stdin, camelCase | `{sessionId, timestamp (epoch ms), cwd, toolName, toolArgs}`. **`toolArgs` is a JSON string**, not an object. | `preToolUse.camel.edit.stdin.json` | High |
| 2b | `PreToolUse` stdin, PascalCase | `{hook_event_name, session_id, timestamp (ISO), cwd, tool_name, tool_input}`, with `tool_input` an object. It looks like Claude's, but **`tool_name` is Copilot's runtime name (`edit`, `create`), not `Edit`/`Write`**, and the path is **`tool_input.path`, not `tool_input.file_path`**. | `PreToolUse.pascal.edit.stdin.json`, `PreToolUse.pascal.create.stdin.json` | High |
| 2c | `postToolUse` stdin | camelCase adds `toolResult: {resultType, textResultForLlm}` (with `toolArgs` still a string). PascalCase adds `tool_result: {result_type, text_result_for_llm}`. A Claude-format plugin file gets the PascalCase shape. | `postToolUse.camel.create.stdin.json`, `PostToolUse.pascal.create.stdin.json`, `PostToolUse.claude-format-plugin.edit.stdin.json` | High |
| 3a | Deny output | A JSON object on stdout with exit 0 denies. **Both** the documented top-level `{"permissionDecision":"deny","permissionDecisionReason":…}` and Claude's `{"hookSpecificOutput":{"permissionDecision":"deny",…}}` were honoured: the tool failed with `Denied by preToolUse hook: <reason>` (code `denied`), and the model saw that text. | `cli-debug-log-excerpts.txt` run C | High |
| 3b | Exit-code meaning | **Measured against the docs: exit 2 does NOT deny on 1.0.56.** A `preToolUse` hook that wrote a reason to stderr and exited 2 was logged (`[hook stderr] …`) and the edit then ran and succeeded. [A] says exit 2 "is treated as a deny" for `preToolUse`. `write-guard.sh`'s contract (exit 2 + stderr) therefore cannot block under Copilot even when it runs. Not measured: other non-zero codes ([A]: fail-closed), timeouts ([A]: fail-open). | `cli-debug-log-excerpts.txt` run B; [A] exit-code table | High (measured once, unambiguous) |
| 3c | Can `postToolUse` block or speak? | It cannot undo the write. `{"additionalContext": "…"}` on stdout reached the model, appended to the tool result as "Additional guidance from postToolUse hooks:". Plain text on stderr (which is how `semconv-lint.sh` reports) did not reach the model. | `cli-debug-log-excerpts.txt` run E; [A], [C] | High |
| 4 | File write and edit tool names | `create` with `{path, file_text}`, and `edit` with `{path, old_str, new_str}`. Path field: `path`, absolute. [A] also maps `str_replace_editor` and `apply_patch` to `Edit`. Some models may call those; only `gpt-4.1` was run here. | stdin fixtures; [A] tool-name table | High for `create`/`edit`; `apply_patch`/`str_replace_editor` Unverified |
| 5 | Plugin-root variable | **All three are set** in the hook's environment: `CLAUDE_PLUGIN_ROOT`, `PLUGIN_ROOT`, `COPILOT_PLUGIN_ROOT` (plus `CLAUDE_PLUGIN_DATA`/`COPILOT_PLUGIN_DATA`). `${CLAUDE_PLUGIN_ROOT}` and `${PLUGIN_ROOT}` were also expanded inside the command string. | `hook-process-env.json`; the debug log shows `bash "<COPILOT_HOME>/installed-plugins/otel-as-code/otel-as-code/hooks/semconv-lint.sh"` | High |
| 6a | Plugin hooks with the user's repo as cwd | Yes, they run: installed-plugin hooks fired for a session in an unrelated repo. | debug log run A | High |
| 6b | Hook process cwd | **The plugin's install directory, not the user's repo.** The repo arrives as the payload's `cwd` and as `CLAUDE_PROJECT_DIR` / `COPILOT_PROJECT_DIR` (both set to the repo by Copilot). `write-guard.sh` and `semconv-lint.sh` resolve their sentinels from `CLAUDE_PROJECT_DIR`, so `--force` / strict mode find the right `.claude/`. `session-summary.sh` runs `git status` in its process cwd, so under Copilot it would summarise the plugin cache (which is a git checkout, see note 2), not the user's repo. | `hook-process-env.json`; `hooks/session-summary.sh` (`git status` with no `-C`) | High for cwd; Medium for the session-summary consequence (read from code, its output not captured) |
| 7 | `sessionEnd` | Exists, fires at the end of a `-p` run, and the Claude-format `SessionEnd` from `hooks/hooks.json` fires too. Payload: `{sessionId, timestamp, cwd, reason}` (camelCase) or `{hook_event_name, session_id, timestamp, cwd, reason}` (PascalCase), with `reason: "complete"` here. [A]: output is not processed. | `sessionEnd.camel.stdin.json`, `SessionEnd.pascal.stdin.json` | High |

## Step 3: what happens to `hooks/hooks.json` (Claude format)

| # | Question | Answer | Evidence | Confidence |
|---|---|---|---|---|
| 8 | Used, ignored or an error? | **Partly used, silently.** It loads without error (`Loaded 3 hook(s) from 1 plugin(s)`), `PostToolUse` → `semconv-lint.sh` and `SessionEnd` → `session-summary.sh` run, but **`PreToolUse` never runs**: not with matcher `Write|Edit`, not with `*`, not with `--allow-all-tools`, not with `--allow-tool=write`. A Copilot-format `preToolUse`/`PreToolUse` in the same session did fire. So `write-guard.sh` is absent under Copilot, and the overwrite of the marker-stamped `tracing.py` went through. | debug log run A; logger plugin `spike-claude-fmt` (both groups, zero PreToolUse captures, two sessions) | High |
| 9 | Do the hooks that run do anything? | **No.** `semconv-lint.sh` runs after every write but reads `tool_input.file_path`, finds nothing, and exits 0 silently. Replaying the captured payload into the real script: as sent → exit 0, no output. With only `path`→`file_path` and the tool name renamed → it warns `'http.method' is deprecated since semconv 1.23`. The same replay into `write-guard.sh` → as sent, exit 0; renamed, exit 2 "blocking overwrite of existing generated OTel file". Even with that fixed, the lint's stderr would not reach the model (row 3c). | replay of `PostToolUse.claude-format-plugin.*` / `PreToolUse.pascal.edit.*` through `hooks/*.sh` | High |
| 10 | Matcher | The Claude-format `Write\|Edit` matcher did match `create`/`edit` (aliases, as [A] documents), but `semconv-lint.sh` also ran for a `report_intent` call in one session, so it does not reliably filter out other tools. A flat Copilot entry with no matcher fires for every tool, `report_intent` included. A bridge must check the tool name itself. | `cli-debug-log-excerpts.txt` run D | Medium |
| 11 | Would `hooks/hooks.json` plus a Copilot-format file fire twice? | **Not inside one plugin.** A plugin with both a root `hooks.json` (flat) and `hooks/hooks.json` (nested) loaded only the root file, and the nested one was ignored (`Loaded 4 hook(s) from 2 plugin(s)` = 3 from otel-as-code + 1). [B] lists both as default paths, and the root one wins. **Across sources they would**: [A] "all hook entries from all sources are run", and [C] warns to check for duplicates. So a user who also copied hooks into `.github/hooks/` would get them twice. | run D; [A], [B], [C] | High within a plugin; Medium across sources (docs) |

## Step 4: VS Code Copilot agent mode (unverified, docs only)

| Question | What the docs say | Confidence |
|---|---|---|
| Same hooks as the CLI? | [C] and [D]: a Copilot hook config fires for VS Code, the GitHub Copilot app and the CLI, which share one harness. Same event names and the same two payload formats. | Unverified |
| Plugin hook files | [D]: Copilot format is `hooks.json` at the plugin root, Claude format is `hooks/hooks.json`, and Agent Plugins 1.0 uses `com.github.copilot/hooks/hooks.json`. The VS Code and CLI pages differ slightly on the Copilot-format path. | Unverified |
| Root variable | [D]: `${PLUGIN_ROOT}` or `${CLAUDE_PLUGIN_ROOT}` are expanded and also set in the hook's environment. | Unverified |
| Deny / context | [C]: top-level `permissionDecision: "deny"` for `preToolUse`, and top-level `additionalContext` for `postToolUse`. | Unverified |

Because the CLI measurably disagrees with [A] on exit 2 and silently drops Claude-format
`PreToolUse`, assume VS Code does too until someone runs it.

## Notes

1. **Project-level hooks did not load in any run.** Logger entries in the scratch repo's
   `.github/hooks/spike-logger.json` (flat, both naming modes) and `.claude/settings.json`
   (Claude format) never fired, and the debug log never mentions them. Folder trust in `-p` mode is
   a guess, not a finding. This does not affect the recommendation, which relies on the plugin
   route, but "users can drop a file in `.github/hooks/`" is **not** established.
2. **A local-marketplace install copies the whole working tree,** gitignored files included
   (`.env`, `.remember/`, `.claude.local.md`, `.git`), into `~/.copilot/installed-plugins/`.
   Contributors testing this way should know their untracked files are copied. A release
   installed from GitHub would carry only tracked files.
3. Copilot ran inside a Claude Code session here, so `CLAUDECODE`/`CLAUDE_CODE_*` variables were
   inherited. `CLAUDE_PROJECT_DIR` was not inherited: its value was the scratch repo, not this
   one, so Copilot set it.
4. Only `gpt-4.1` was available on this account. Tool choice (`create`/`edit` vs `apply_patch`)
   is model-dependent, so a bridge should handle the `apply_patch` envelope the way
   `hooks/codex/_bridge.py` already does.

## Recommendation

**(b) A Copilot bridge like `hooks/codex/` is needed.** The Claude hooks do not work unchanged,
and nothing blocks a bridge.

The Claude hooks fail without any error, which is the worst case for the positioning. Under
Copilot the plugin installs, `hooks/hooks.json` loads, `semconv-lint.sh` visibly runs after every
write, and nothing is checked:

1. `PreToolUse` from `hooks/hooks.json` never runs, so there is no write guard at all.
2. Even if it ran, exit 2 + stderr does not deny on 1.0.56. Only a JSON `permissionDecision` does.
3. The payload carries `tool_input.path` (and `file_text` / `old_str` / `new_str`) under Copilot's
   own tool names, so both scripts find no file and exit 0.
4. The lint's stderr never reaches the model. Only `additionalContext` JSON does.
5. The hook process's cwd is the plugin cache, which breaks `session-summary.sh`'s `git status`.

Every one of these is a translation problem the Codex adapters already solve for a different
payload: synthesise the Claude-shaped payload, run the unchanged `hooks/*.sh`, and turn exit 2 +
stderr into the host's deny / context JSON. The measured seam is a root-level `hooks.json` in
Copilot's flat format (`version: 1`, camelCase `preToolUse` / `postToolUse` / `sessionEnd`),
calling `python3 "${CLAUDE_PLUGIN_ROOT}/hooks/copilot/<adapter>.py"`. Inside one plugin Copilot
then ignores `hooks/hooks.json`, so nothing fires twice. The adapter should parse `toolArgs`
(a string), map `create`/`edit` (and `apply_patch`, `str_replace_editor`) to `Write`/`Edit`, run
the scripts with `cwd` = the payload's `cwd`, emit `permissionDecision: "deny"` on exit 2, and
emit `additionalContext` for lint findings.

**Claude Code ignores a root-level `hooks.json`, so the seam is one-sided** (checked
2026-11-19, Claude Code 2.1.311, `claude -p --plugin-dir` with one `Write`). Plugin A, with only a
Copilot-format root `hooks.json`, fired nothing, raised no error and wrote nothing to stderr.
Plugin B had a Claude-format root `hooks.json` next to `hooks/hooks.json`, and only
`hooks/hooks.json` fired, once. A copy of this repo with a flat root `hooks.json` added still
passes `claude plugin validate . --strict`. So each host reads exactly one of the two files, and
neither guardrail runs twice. Confidence: High for 2.1.311; a future Claude Code release that
starts reading the root file would double-fire, which the bridge's tests should notice.

The Claude plugin directory build (`scripts/build-directory.sh`) does not need the root file
or the Copilot adapters, since that build is for Claude Code only. Check that
`tests/directory-build.test.sh` agrees once the adapters exist.
