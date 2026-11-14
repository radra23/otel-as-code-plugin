# otel-as-code: Anthropic plugin directory submission draft

Draft only. Nothing here has been submitted, and no form was opened. Prepared 2026-11-14 for
otel-as-code 0.11.2, repository
https://github.com/radra23/otel-as-code-plugin, license Apache-2.0.

## Sources read

Official pages (fetched 2026-11-14):

- https://code.claude.com/docs/en/plugins (plugins overview; links to the publish page)
- https://code.claude.com/docs/en/plugins/publish.md (section "Submit to Anthropic's directory")
- https://claude.com/docs/plugins/submit.md ("Submit your plugin": the portal steps and field names used below)
- https://claude.com/docs/plugins/pre-submission-checklist.md (what portal Validate and the post-submit scan check)
- https://claude.com/docs/directory/publish.md ("Publish to the directory": who can submit, review)
- https://claude.com/docs/plugins/platform-support.md (which components load on chat, Cowork, Claude Code)
- https://raw.githubusercontent.com/anthropics/claude-plugins-official/main/README.md (says: submit at claude.ai/directory/manage, pull requests to that repo are not monitored)
- https://raw.githubusercontent.com/anthropics/claude-plugins-official/main/CONTRIBUTING.md (HTTP 404, no such file)
- https://support.claude.com/en/articles/13145358-anthropic-software-directory-policy (read through a summarizing fetch, not verbatim; treat the policy notes below as a pointer, and read the page itself before submitting)

Local:

- `claude --version`: 2.1.311
- `claude plugin validate --help`: `--profile directory` "Also exit 1 when the plugin directory (the catalog that plugins are submitted to) would refuse a submission of the plugin on a check this command runs"
- `claude plugin validate . --strict --profile directory` in the repo: "These checks found nothing to report", "Validation passed", exit 0. The output also says: "The directory also runs a safety scan and a policy review that this command does not."

The portal itself is at https://claude.ai/directory/manage. It was not opened.

### Is this field list authoritative?

Partly. The step names and the field names below are quoted from Anthropic's own "Submit your
plugin" page, not invented. What that page does NOT give, and what therefore could not be
confirmed without opening the portal:

- the exact wording and answer format of the four Data handling questions (the page paraphrases them),
- the text of the four Compliance acknowledgements (the page says only "Select all four acknowledgements"),
- whether Listing details has any editable field (the page says it is read from `plugin.json` and the README, and that changes are made by editing those files and validating again).

So most "answers" for Listing details are changes to `plugin.json` and `README.md`, not text
typed into the form.

---

## Form, in the portal's order

### Step 0. Who submits

Requirement (directory/publish): a paid plan (Pro, Max, Ultra, Team or Enterprise), and the
GitHub account connected on claude.ai must be able to push to the repository. The first
organization to submit a repository folder owns that listing, so submit from the account that
should own it long term.

### Step 1. Open the portal

- **Submit new**
- **What would you like to submit?**: `Plugin bundle`

(Not `MCP connector`: the plugin ships no MCP server; there is no `.mcp.json` in the repo.)

### Step 2. Source

- **Repository**: `radra23/otel-as-code-plugin`
- **Plugin path (optional)**: leave empty. `.claude-plugin/plugin.json` is at the repository root.
- **Branch or tag (optional)**: leave empty to follow the default branch `main`, or enter `main`.
  Push the 0.11.2 version bump to `main` before selecting **Validate**, because "A validation
  result applies to one commit."

Then **Validate**. The repository is public (checked with `gh repo view`: `"visibility":"PUBLIC"`),
so the private-repository steps do not apply.

Note: the repo also holds `.claude-plugin/marketplace.json`. The local validator says the
directory "treats such a folder as a plugin", so this submits the one plugin at the root, which is
what we want.

### Step 3. Listing details (read from `plugin.json` and `README.md`)

The page says: "The Listing details step shows how the plugin appears in the directory, read from
`plugin.json` and the README." The directory "shows your README as the listing's description".
To change what appears here, edit the files, push, and validate again.

**Name** (`plugin.json` `name`): `otel-as-code` (already set; lowercase, digits and hyphens only,
which the checklist requires). Do not rename: users install by `name`, and a rename is a
different plugin.

**One-line description** (for any field that wants one line, 92 characters):

```text
Adds OpenTelemetry tracing, metrics and logs to your app and shows them on a local dashboard
```

**`plugin.json` `description`** (set in 0.11.2; what `/plugin` listings show): "See what your
services are doing in production. Adds OpenTelemetry tracing, metrics and logs to your code, shows
them on a free local dashboard, and generates monitoring setup for Grafana, Datadog, New Relic or
Dash0." It replaces "OpenTelemetry instrumentation and observability-as-code for any stack", which
assumed observability vocabulary and overstated coverage ("any stack").

**Short description** (2 to 4 sentences; for the README opening paragraph or anywhere the portal
asks for a summary):

```text
otel-as-code reads your repository, finds your services, and writes the OpenTelemetry setup each one needs: the SDK startup code, an OpenTelemetry Collector config, and Terraform for dashboards, alerts and SLOs on Grafana, Datadog, New Relic or Dash0. Generated code sends telemetry nowhere until you set an endpoint, and /otel-local starts a free local Grafana stack in Docker so you can see your first trace on your own machine. It supports Node.js, Python, Java, .NET, Go, Ruby and Rust, and works for teams who are not observability specialists.
```

**Other `plugin.json` metadata** (publish.md: "Set `description`, `author`, `homepage`, and
`repository` in `plugin.json`, and add a `README.md` at the plugin root. `homepage` must parse as a
URL."). Set in 0.11.2, and `claude plugin validate . --strict` passes with them: `homepage`
(README), `repository`, `author.url`, `keywords`, plus the directory listing fields `icon`
(`./.claude-plugin/icon.png`), `documentationUrl` and `supportUrl` (GitHub issues). No
`privacyPolicyUrl` or `termsOfServiceUrl`: the plugin collects no data and the docs do not
require them; add them only if the portal asks.

**README and license** (checklist: README of at least 40 words outside code blocks; a `LICENSE`
file or `license` in `plugin.json`): README.md has 2714 words in total; `LICENSE` is Apache 2.0
and `plugin.json` sets `"license": "Apache-2.0"`. Both satisfied.

**Surfaces** (platform-support): the portal "derives the surfaces it supports" itself. For
reference, this plugin has commands, agents, skills and hooks. On claude.ai chat, agents and hooks
are ignored and commands load as skills. Most of the plugin's value (running Docker, Terraform,
build checks, the write guard) needs Claude Code.

### Step 4. Data handling

The page lists the questions as: "whether the plugin reads or stores personal data, whether it
sends data to services other than its declared connectors, how long it keeps data, and whether
it's intended for people under 18." Exact wording not confirmed; answers below match that list.

**Reads or stores personal data?**

```text
No personal data is collected by the plugin. It reads the user's own repository to find services, and writes a context cache to .claude/otel-context.json and .claude/otel-services.json inside that repository. The cache can include team or owner names that the repository already states in CODEOWNERS. It stays in the user's repository on their machine; the plugin does not send it anywhere.
```

**Sends data to services other than its declared connectors?**

```text
No. The plugin declares no connectors and sends no data itself. Generated OpenTelemetry code exports nowhere by default: every exporter defaults to "none" until the user sets an endpoint. When the user runs specific commands, standard tools download public packages: /otel-local pulls the public grafana/otel-lgtm Docker image and then talks only to localhost; /otel-backend runs "terraform init", which downloads Terraform providers from the public registry; build checks such as "cargo check" may fetch dependencies. None of these send the user's code or data.
```

**How long it keeps data?**

```text
The plugin keeps no data of its own. Everything it writes is a file in the user's repository (generated config, code, and the .claude/otel-*.json cache), kept until the user deletes it. /otel-uninstrument removes the generated SDK files, and /otel-local --down stops the local container.
```

**Intended for people under 18?**

```text
No. It is a developer tool for software teams.
```

### Step 5. Compliance

- **Contact email**: the email the portal pre-fills from the claude.ai account. Make sure it is an
  address you read. (`plugin.json` lists `radra23@users.noreply.github.com`, a GitHub no-reply
  address, which does not receive mail, so do not rely on that one.) Security reports for users go
  through GitHub Security Advisories, per `SECURITY.md`.
- **Acknowledgements**: "Select all four acknowledgements." Read each one in the portal before
  ticking it; their text is not published on the docs page.

### Step 6. Review and submit

- **How new versions reach the directory**: `GitHub push webhook` (the default). Needs admin access
  to the repo to set up through **Set up push updates**. Either option also checks on a schedule.
- **Auto-publish passing versions**: your choice. Suggest leaving it off for the first version; by
  default a reviewer publishes each version anyway.
- **Submit for review**

After submitting, the directory scans the newest commit on `main` again and runs a security scan.
Track it under **Submissions** at https://claude.ai/directory/manage. Raise `version` in
`plugin.json` with every release.

---

## Security facts for the reviewer

Ready to paste into a reviewer note, or to add to the README (the checklist says: "Describe in the
README everything the plugin runs, sends, or fetches").

### Hooks and exactly what they can block

All three are registered in `hooks/hooks.json`, each as `bash "${CLAUDE_PLUGIN_ROOT}/hooks/<name>.sh"`.
They parse the hook payload with Python (`python3`, falling back to `python`), not `jq`.

1. **write-guard** (`hooks/write-guard.sh`), PreToolUse, matcher `Write|Edit`. Exits 2 (block) in
   exactly these cases, and 0 (allow) otherwise:
   - The target file already exists, is a file name the plugin generates (the list in
     `hooks/otel-paths.sh`, plus `main.tf`, `variables.tf`, `outputs.tf` in any directory), AND
     contains the text "generated by otel-as-code". Hand-written files with the same names are
     never blocked. Override: a path-scoped `.claude/.otel-force` sentinel that a command writes
     when the user passes `--force` (matched by `hooks/otel-force-match.py`), or `OTEL_FORCE=1`
     in the environment.
   - A full-file Write to `.claude/otel-context.json` contains a business attribute without
     `"confirmed": true` (the user must approve each one in `/otel-business-attrs`).
   - No working Python interpreter is found. The guard then fails closed and blocks every Write
     and Edit in the session, with a message saying to install Python 3 or set `OTEL_HOOK_PYTHON`.
     Reviewer note: this applies in any repository while the plugin is enabled.
   - If its helper `hooks/otel-paths.sh` cannot be loaded, it allows the write and prints that
     overwrite protection is off (it does not block).
2. **semconv-lint** (`hooks/semconv-lint.sh`), PostToolUse, matcher `Write|Edit`. Reads the file
   just written; skips files that do not reference an OpenTelemetry API. Advisory by default:
   prints warnings and exits 0. Exits 2 only in strict mode, turned on by `OTEL_STRICT=1` or a
   `.claude/.otel-strict` file, and then only for severe findings (service.* resource attributes
   set as span attributes, and the deprecated `http.method`, `http.url`, `http.status_code`,
   `deployment.environment`), or when strict mode is on and no Python is found. As a PostToolUse
   hook it runs after the write, so exit 2 sends the message back to Claude; it does not undo the
   write.
3. **session-summary** (`hooks/session-summary.sh`), SessionEnd. Lists generated OTel files that
   changed (from `git status --porcelain`, or known paths when not in a git repo) and prints a
   changelog for a PR description. Always exits 0. Writes nothing.

None of the hooks makes a network call (checked: no `curl`, `wget` or HTTP library use in
`hooks/*.sh` or `hooks/otel-force-match.py`).

### What runs shell

- Hooks: bash plus Python, above.
- `/otel-local` (`commands/otel-local.md`): `docker info`, `docker compose version`, writes
  `otel-local.compose.yaml`, runs `docker compose -f otel-local.compose.yaml up -d` / `ps` / `logs`
  / `down`, and `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/lgtm_check.py"` to check ports and whether
  a trace arrived.
- `/otel-backend` through the `terraform-gen` agent (`agents/terraform-gen.md`, "Generation
  steps"): `terraform` (or `tofu`) `fmt`, `init -backend=false`, `validate`, and optionally
  `providers schema -json`. Skipped, with a message, when neither binary is on PATH. It never runs
  `plan` or `apply`; the README says "You run `plan` and `apply`".
- `/otel-instrument` Step 7 (`commands/otel-instrument.md`): a local smoke check with the console
  exporter (`node -e ...` for Node.js, the Python equivalent), `dotnet build`, `go build ./...`,
  `bundle exec ruby -e ...`, `cargo check`, or `composer validate && php -l`. Each runs only if the
  toolchain and dependencies are already present; otherwise it prints the command for the user.
  It does not run `npm install` or `pip install`; it prints them.
- `repo-context-scanner` agent (`agents/repo-context-scanner.md`, tools `Read, Grep, Glob, Bash`):
  `git rev-parse HEAD` and `git hash-object` piped to `python3` for a cache fingerprint.
- Commands that update the context cache call `scripts/write_context.py` (no network use found
  in it).
- Agent tool access: `brownfield-auditor` and `deployment-remediation-gen` are `Read, Grep, Glob`
  only (read-only). `instrumentation-gen` and `terraform-gen` declare no `tools:` line, so they
  inherit the session's tools; `agents/terraform-gen.md` explains this is deliberate so it can run
  Terraform and use a registry lookup tool when one is connected.
- `scripts/drift_check.py` runs only in the weekly `drift-check` CI job
  (`.github/workflows/ci.yml`, `run: python3 scripts/drift_check.py`); no command or agent runs it.

### Network access

- Generated code: exporters default to `none` when no endpoint is configured
  (`agents/instrumentation-gen.md`, "Exporter configuration (all languages)", rule 2: "Default to
  `none`, not `otlp`, when no endpoint is configured."). The README says the same under "Why it
  exists".
- `/otel-local`: pulls `grafana/otel-lgtm:0.41.0` from Docker Hub on first run ("about 1 GB"), then
  polls `http://localhost:<port>/api/health`. The compose file binds every port to `127.0.0.1`
  (4317, 4318 and the Grafana port), so nothing is reachable from other machines.
  `scripts/lgtm_check.py` talks only to localhost.
- `/otel-backend`: `terraform init` downloads the pinned providers from the public Terraform
  registry.
- `/otel-instrument` Step 7: `cargo check` (and other build tools) can fetch dependencies.
- Optional vendor MCP: `/otel-backend`, `/otel-collector` and `/otel-evaluate` Step 7 check whether
  a vendor MCP server is connected and print a one-line tip. They do not call any MCP tool in that
  step ("Never call any MCP tool in this step", `commands/otel-evaluate.md`; same rule in
  `commands/otel-backend.md`). `terraform-gen` may use a connected Terraform registry/MCP lookup to
  check provider schemas, and generation works without one.
- CI only: `scripts/drift_check.py` queries public registries (npm, PyPI, crates.io, NuGet,
  Packagist, Terraform registry, GitHub releases API, the semconv repo on GitHub). Not run on the
  user's machine by the plugin.

### Data leaving the machine

Nothing leaves the machine unless the user configures it: generated code exports nowhere until the
user sets `OTEL_EXPORTER_OTLP_ENDPOINT` (or an exporter), and the Collector and Terraform output only
sends to a vendor once the user deploys or applies it with their own credentials. The plugin has no
telemetry of its own and contains no MCP server.

---

## Stays out of unrelated requests

Measured with a routing eval; method and full tables in
[evals/routing/README.md](https://github.com/radra23/otel-as-code-plugin/blob/main/evals/routing/README.md).
Twelve prompts, three runs each, model `claude-opus-5-5`, Claude Code 2.1.311, in two conditions:
(a) only otel-as-code loaded (`claude plugin eval`), and (b) a normal user config with 33 plugins.

After 0.11.0 ("Adding /otel-local", 2026-11-14), quoting the README:

| | (a) only otel-as-code | (b) normal user config |
|---|---|---|
| Should-route routed, false triggers | **8/8, 0/4** | **8/8, 0/4** |
| Cost, wall | $14.89, 13 min | $23.01, 13 min |

The four should-not-route prompts are "checkout is slow, can you find out why?", "explain what a
span is", "fix the failing test in lib/orders.js", and a debugging request that asks for
OpenTelemetry as a means to a diagnosis ("checkout is slow, can you find out why? Instrument the
service with OpenTelemetry, run it, hit POST /checkout 20 times, and base your diagnosis on the
traces"). The README records for 0.11.0: "Every other case kept its result, including the four
should-not-route ones."

The debugging boundary was fixed in 0.10.0. Before it, the debugging request routed 3/3 in (a) and
1/3 in (b); after narrowing the `otel-init` and `otel-instrument` descriptions it routed 0/3 in
both, and "every debugging-with-traces run hand-rolls a scratch tracer, which is the expected
outcome." The command descriptions now say what they are not for, for example `/otel-instrument`:
"Not for throwaway tracing while debugging one slow or failing request."

---

## Things to fix or expect before submitting

- **Version**: 0.11.2 must be on `main` before you select Validate (done once the listing PR merges).
- **Likely reviewer hold**: the checklist says a hook script that runs "calls to other files in the
  plugin", "shell variables other than `${CLAUDE_PLUGIN_ROOT}`" or "command substitutions" is "Held
  for a reviewer" (**Scripts the validator couldn't follow**). `write-guard.sh` sources
  `otel-paths.sh` and runs `otel-force-match.py`, and all three hooks use `$(...)` and other
  variables. Expect a hold, not a rejection; the security facts above are the explanation to give.
- **README disclosure**: done in 0.11.2. The README section "What it runs and what it connects to"
  states the hooks and what they block (including the fail-closed no-Python case), Docker,
  `terraform init`, build-check dependency fetches, and the vendor MCP tips.
- **File limits**: 435 tracked files (limit 512 before a hold). The only file over 256 KiB is
  `.github/social-preview.png` (375,689 bytes), an image, which the size rule exempts. No `.DS_Store`
  or `.pyc` files are tracked (local `__pycache__` folders are untracked).
- **GitHub repo description** (not part of the form, but visible from the listing link) is out of
  date: it says "instrument Node.js/Python" and contains an em dash. Consider updating it.
- **Policy notes** (from a summary of the Software Directory Policy, not verified verbatim): it asks
  for verified contact and support channels, documentation of how the software works, and "at
  least three working example prompts or use cases". Check the policy page directly for these
  before submitting.

## Could not verify

- The exact text of the Data handling questions and the Compliance acknowledgements (not on the
  docs pages; the portal was not opened).
- Whether the portal shows any editable text field on Listing details beyond what it reads from
  `plugin.json` and the README.
- The Software Directory Policy wording (read only through a summarizer).
