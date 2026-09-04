---
description: Generate OTel SDK bootstrap and OTLP wiring for this service
argument-hint: "[language] [--service <id>] [--fix <ids>] [--experimental] [--force] [--dry-run]"
---

# /otel-instrument [language] [--service <id>] [--fix <ids>] [--experimental] [--force]

Generate OTel SDK bootstrap and OTLP wiring for one service.

## Flags
- `[language]` — optional; `nodejs`, `python`, `java`, or `dotnet`. If omitted, derived from the
  selected service (Step 2). It narrows the candidate services; it does not pick one.
- `--service <id>` — the service to instrument, by `id` from the context JSON. Skips the
  Step 2 prompt.
- `--fix <ids>` — apply only the findings with these IDs from the most recent
  `/otel-evaluate` report. IDs are the `<CAT>-<id>` form that report emits (e.g.
  `--fix CV-a1b2,SH-2a55`), and in a multi-service repo they are service-qualified
  (`--fix bot:CV-a1b2`) — see the finding-ID scheme in `agents/brownfield-auditor.md`. Scopes
  regeneration to those findings
  instead of rewriting whole files. See Step 5.
- `--experimental` — unlock pre-Stable signals (e.g. logs for Python). Passed to
  both `language-maturity` and `semconv-discipline` skills.
- `--force` — overwrite existing generated artifacts. Required if the write-guard hook blocks
  a re-generation. **`--force` is a full regeneration and discards hand edits** — read the
  warning in Step 4 before using it.
- `--dry-run` — preview without writing. Generate exactly as normal, then print a unified diff of
  each would-be file against what is on disk (or "would create" for a new file) and exit WITHOUT
  writing — non-zero if anything would change, so it composes in CI. Pairs with `--force`: it is
  the only way to see what a destructive regeneration would do before it discards your edits. See
  the Dry run section.

## Step 1: Load context

Read the `otel-as-code:language-maturity` skill — apply all maturity gating rules.

Check `.claude/otel-context.json`. Apply the freshness rule from `/otel-init` Step 1
(identity-input fingerprint, not `HEAD`). If stale or absent:
- Run `/otel-init` logic inline — dispatch `otel-as-code:repo-context-scanner` **passing the
  existing cache as `priorContext`** so confirmed answers survive, and write what it returns.
  A refresh is a merge, never a replace (see `agents/repo-context-scanner.md`). Pass the same
  `semconvVersion` + `semconvGuidancePath` inputs `/otel-init` Step 2 does — the scanner has no
  `Skill` tool and cannot read the guidance itself.
- Do NOT print the /otel-init success message; just run the scan silently.

## Step 2: Select the target SERVICE

Pick a service first; its language follows from it. Resolving a language alone settles nothing
when two services share one — and `services[0]` is not a safe default, because the first
detected service is frequently a browser SPA whose `language` is `nodejs` and whose runtime
is not Node at all.

1. Build the candidate list: every service in `context.services` with
   `generatorSupported: true`. If `[language]` was given, keep only services with that `language`.
   If `--service <id>` was given, use exactly that one (and validate it below).
2. Then:
   - **Exactly one candidate** → use it. Print: "Target: <name> (<rootDir>, <language>/<runtime>)".
   - **More than one** → list them and ask. Never default to the first:
     ```
     Which service should be instrumented?
       1  checkout-api   api/   nodejs / node    (no OTel detected)
       2  worker         jobs/  nodejs / node    (traces present)
     Not offered: portal-web (web/) — runtime is browser; browser/RUM is out of scope.
     →
     ```
   - **No candidates** → print, for each detected service, its `instrumentableReason`, then exit
     without writing anything:
     ```
     ⚠ No service in this repo can be instrumented by /otel-instrument yet.
       portal-web (web/)  — runtime is browser; browser/RUM instrumentation is out of scope
                            for the MVP. Use an OTel browser SDK / RUM product directly.
       cache (cache/)     — runtime go is not supported yet (v1).
     ```
3. Validate the chosen service before generating. If it has `generatorSupported: false`, refuse:
   ```
   ⚠ <name> cannot be instrumented by this command: <instrumentableReason>
     Generating a Node SDK bootstrap for a browser bundle produces code that cannot run and
     that breaks the build. Nothing was written.
   ```
   Exit. Emitting wrong code is worse than emitting none — do not fall back to a near-match.
4. Derive `language` from the selected service. If it is not `nodejs`, `python`, `java`, or
   `dotnet`:
   - Print: "⚠ <language> is not supported yet. Supported: nodejs, python, java, dotnet.
     v1 will add: go, ruby, php, rust."
   - Exit.

If `context.services` has no `runtime` field at all, the cache predates schema 2 — re-scan
(Step 1) rather than guessing, since `language` alone cannot tell a browser bundle from a
server.

Note: `java` uses the OpenTelemetry Java **agent** (zero-code auto-instrumentation), so the
generated artifact is `otel-java.env` + run instructions, not a source bootstrap file. The
`instrumentation-gen` subagent handles the per-language artifact shape.

## Step 3: Check signal maturity

For the target language, apply the maturity gate rules from `language-maturity` skill.

If any signal is Development-level AND `--experimental` is NOT set:
- Print the Development-level warning from the skill.
- Do not generate that signal's code.
- Print: "Re-run with --experimental to generate Development-level signals."

## Step 4: Find the existing artifact, and gate the overwrite

**Resolve the existing bootstrap from the cache, not from a guessed filename.** Testing for
`tracing.js` in the service root misses `api/src/tracing.ts` on both the name and the depth,
concludes nothing exists, and writes a *second* bootstrap beside the real one — after which the
SDK starts from whichever the entry point happens to import.

1. If `service.existingOtel.bootstrapFiles` is non-empty, that is the answer. Use those paths.
2. Otherwise glob the **whole service subtree** (`<rootDir>/**`, excluding `node_modules`,
   `dist`, `build`, `.venv`) for `tracing.*`, `telemetry.*`, `opentelemetry.*` and
   `otel-java.env`. The extensions come from `hooks/otel-paths.sh`, which is also what the
   write-guard protects — so anything the guard will block is something this step finds.
3. Only if both come back empty is there no existing artifact; go to Step 5.

If artifacts were found AND `--force` is NOT set:
- Print: "⚠ Generated artifact already exists: <path(s)>. Use --force to overwrite,
  or --fix <ids> to apply specific /otel-evaluate findings without a full rewrite."
- Exit.

If artifacts were found AND `--force` IS set:
- Print the overwrite warning, in full, and get confirmation before writing:
  ```
  ↻ --force regenerates these files from scratch:
      api/src/tracing.ts
      api/src/telemetry.ts
    Any hand-written changes in them will be lost. By the time regeneration is worth running,
    these files have usually been edited by hand.

    Recommended first: `git diff` them after generation, or copy them aside now.
    Narrower alternative: /otel-instrument --fix <ids> applies specific findings instead.

    Continue? [y/N]
  ```
  If the files are tracked and clean in git, say so — "both files are committed, so `git diff`
  will show exactly what changed" — and the confirmation can be a formality. If they are dirty
  or untracked, insist: back them up first.
- Read each file that will be overwritten BEFORE regenerating, and pass its content to the
  subagent as `preserve` (Step 5). Deliberate local decisions — a handler wrapper for a runtime
  with no inbound HTTP server, an exporter switch, a bounded `error.type`, a documented
  exclusion — must survive regeneration or be re-emitted; they are the reason the file is worth
  keeping.
- Authorize the overwrite for the `write-guard` hook by listing the paths the subagent will
  overwrite in the `.claude/.otel-force` sentinel, one per line. **Truncate the sentinel as you
  write it** (`>`, not `>>`) so a leftover from an aborted earlier run can never grant a standing
  overwrite authorization — write all paths in a single `printf`:
  ```
  mkdir -p .claude && printf '%s\n' "<path 1>" "<path 2>" > .claude/.otel-force
  ```
  A slash-command flag cannot set an env var for the hook process, so this file is how
  `--force` reaches the guard. List the paths resolved in this step, exactly as found. Absolute
  or repo-relative both work: the guard normalises both sides before comparing (drive letters,
  backslashes, `.`/`..`, relative-to-project), so the sentinel does not have to guess the
  host's path convention. It stays path-scoped — a path you do not list is still protected.

## Step 5: Dispatch instrumentation-gen subagent

Pass to `otel-as-code:instrumentation-gen`:
- `context`: the loaded context JSON
- `service`: the SELECTED service object from Step 2
- `language`: the language derived from it
- `runtime` / `host`: from the selected service — these decide whether an inbound HTTP server
  exists to instrument (see the serverless section of `instrumentation-gen`)
- `experimental`: boolean from --experimental flag
- `semconvVersion`: the `SEMCONV_VERSION` from the `semconv-discipline` skill (the subagent has no
  `Skill` tool; it stamps this into the header and must not restate it from memory)
- `languageMaturityPath`: `${CLAUDE_PLUGIN_ROOT}/skills/language-maturity/SKILL.md` — the subagent
  `Read`s it for the per-language signal-maturity matrix
- `existingArtifacts`: the paths resolved in Step 4
- `preserve`: the current content of each file being overwritten, when `--force` was used
- `fixList`: when `--fix <ids>` was given, the findings with those IDs from the most recent
  `/otel-evaluate` report — each with its `file`, `line`, and required change. With a
  `fixList`, the subagent edits only those sites and leaves the rest of each file alone;
  it does not regenerate the file.

## Dry run (`--dry-run`)

If `--dry-run` was passed, do NOT let the subagent write and do NOT proceed to Steps 6–8's
side effects. Instead: pass `dryRun: true` in the Step 5 dispatch, so `instrumentation-gen`
returns each intended file as `{path, content}` rather than writing. Then, for each returned file:
- if it exists on disk, print a unified diff of the returned content against the on-disk content
  (e.g. write the content to a temp file and `git diff --no-index <disk> <tmp>`);
- if it does not exist, print `would create <path> (<n> lines)`.
Write nothing, do NOT touch the cache (Step 6) or the `.claude/.otel-force` sentinel, and exit
**non-zero if any file would change** (zero if the diff is empty) so `--dry-run` composes in CI.
This is the only way to preview a `--force` regeneration before it discards hand edits.

## Step 6: Record what was written back into the cache

The subagent handles file writing. After it returns, **update
`.claude/otel-context.json` for the target service** before printing anything:

```json
"existingOtel": {
  "hasTraces": true,
  "hasMetrics": true,
  "hasLogs": false,
  "sdkVersion": "<resolved>",
  "sdkPackages": ["@opentelemetry/sdk-node@^0.221.0", "..."],
  "bootstrapFiles": ["api/src/tracing.ts", "api/src/telemetry.ts"],
  "wiredInto": ["api/package.json#scripts.start"],
  "source": "recorded-by-command",
  "observedAt": "<ISO-8601>"
}
```

Nothing else updates this, so skipping it makes `/otel-evaluate` — the obvious next command —
exit with "No existing OTel instrumentation detected" immediately after instrumentation was
generated. Rewrite only `existingOtel` for that service; leave every other field, and every
user-owned field, untouched.

If a `.claude/.otel-force` sentinel was created in Step 4, remove it now so the write-guard
is restored for subsequent writes: `rm -f .claude/.otel-force`.

## Step 7: Verify the bootstrap actually loads and identity is correct

"Generated" is not "working". Before reporting success, prove the bootstrap imports, the SDK
starts, and the resource carries the identity `/otel-business-attrs` confirmed — with a local
**console** smoke that needs no collector and no network. This catches a bootstrap that throws
on import, a wrong `service.name`, or a dropped `service.namespace` / `deployment.environment.name`
immediately, instead of after the user wires up a backend and sees nothing.

Applies to the Node.js and Python source bootstraps. (Java is the zero-code agent — there is no
importable bootstrap to smoke here; its equivalent is running the app under the agent, which the
e2e harness covers. Say that and skip.)

For **.NET** the equivalent check is `dotnet build` — the generated `OpenTelemetry.cs` and the
pasted `Program.cs` line must compile against the added packages. Run it only if the SDK is
present and packages restored; otherwise print the wiring commands from the subagent summary
(add packages → paste the one-liner → `dotnet build`) and note verification was deferred. A
build failure is a failure to fix, not to paper over. (Runtime span emission is the e2e
follow-up, as with Java.)

Run the smoke only if the SDK dependencies are installed (`node_modules` / the venv present). If
they are not, DO NOT fail — print the exact command for the user to run after `npm install` /
`pip install`, and note verification was deferred.

- **Node.js** (adjust the bootstrap path to what was generated):
  ```
  OTEL_TRACES_EXPORTER=console OTEL_METRICS_EXPORTER=none OTEL_LOGS_EXPORTER=none \
    node -e "require('./tracing.js'); const {trace}=require('@opentelemetry/api'); \
    trace.getTracer('otel-verify').startSpan('otel.smoke').end(); \
    setTimeout(()=>process.exit(0), 1200)"
  ```
- **Python** (adjust module name):
  ```
  OTEL_TRACES_EXPORTER=console OTEL_METRICS_EXPORTER=none OTEL_LOGS_EXPORTER=none \
    python -c "import tracing; from opentelemetry import trace; \
    trace.get_tracer('otel-verify').start_span('otel.smoke').end(); tracing.shutdown()"
  ```

Both print the span as JSON on stdout, including its `resource` attributes. Assert on that output:
- a span named `otel.smoke` was printed (the SDK started and the console exporter ran); and
- its resource `service.name` equals the confirmed name, and — when the context has them —
  `service.namespace` and `deployment.environment.name` match what was confirmed.

Report the result plainly: `✓ Verified: bootstrap loads and emits service.name=<name> …`, or, on a
mismatch or an import error, show the discrepancy and treat it as a failure to fix — do not paper
over it. If verification was deferred (deps not installed), say so and give the command above.

## Step 8: Deployment wiring — say what is still required

Print the subagent's summary, then this block. **Do not omit it and do not soften it.** The
generated bootstrap reads `OTEL_EXPORTER_OTLP_ENDPOINT` and hard-codes nothing, which is
correct — and it means the service exports nowhere until the deployment sets it. The generated
Node.js/Python code defaults every exporter to `none` when no endpoint is configured, so the
failure mode is silence rather than a retry loop against `localhost:4317`; that is a safe
default, not a working one. (The .NET OTLP exporter and the Java agent do the opposite — they
default to `localhost:4317` and retry — so for those two, setting the endpoint below is not
just recommended, it is what stops a reconnect loop in the deployed process.)

Use `service.deployment.configFiles` and `service.deployment.endpointConfigured` from the
context to make this concrete rather than generic:

- **`endpointConfigured: true`** — print one line confirming where it is set, and move on.
- **`endpointConfigured: false` and `configFiles` is non-empty** — the highest-impact gap in the
  whole flow (an instrumented service with no endpoint costs money and produces nothing), so do
  more than name it: **detect the target type from the config file and emit the settings in that
  file's own syntax**, then offer to write them in. Map the file to its shape:

  | Config file (`configFiles`) | Target | Emit as |
  |---|---|---|
  | `*.tf` on a function-app / app-service / container resource | Terraform | an `app_settings = { … }` / `env { … }` block on that resource |
  | `*.bicep` | Bicep | `appSettings` array entries (`{ name: '…', value: '…' }`) |
  | `k8s/*.yaml`, `*deployment*.yaml`, `values.yaml`/`Chart.yaml` | Kubernetes | an `env:` list on the container (or ConfigMap keys) |
  | `docker-compose.y*ml` | Compose | an `environment:` map on the service |

  The settings, in every case (`DEPLOYMENT_ENV` ties to the deployment-environment default, see
  the instrumentation-gen notes):
  ```
  OTEL_EXPORTER_OTLP_ENDPOINT   # your collector or vendor OTLP endpoint (do NOT invent it)
  OTEL_EXPORTER_OTLP_PROTOCOL = grpc
  OTEL_TRACES_EXPORTER  = otlp
  OTEL_METRICS_EXPORTER = otlp
  OTEL_LOGS_EXPORTER    = otlp
  DEPLOYMENT_ENV        # this target's environment, e.g. production
  ```

  **If a collector this service points at requires auth:** check for `otelcol-agent.yaml` /
  `otelcol-gateway.yaml` in the repo (root or service root) — if one exists and contains
  `authenticator: bearertokenauth` (generated by `/otel-collector --public`, #107), add one more
  setting to the block above:
  ```
  OTEL_EXPORTER_OTLP_HEADERS = Authorization=Bearer%20<the collector's COLLECTOR_AUTH_TOKEN value>
  ```
  Do NOT invent the token value — name the collector file and tell the user to use the same
  secret they set as `COLLECTOR_AUTH_TOKEN` there. Without this, the instrumented service exports
  nowhere: the `--public` collector rejects every unauthenticated request. The `%20` is required,
  not cosmetic: this env var's values must be percent-encoded per the OTel spec (W3C Baggage
  format) — a literal space works in some SDKs but the OTel Python SDK specifically rejects it,
  failing every export with `UNAUTHENTICATED`.

  Render them in the detected file's syntax — e.g. Terraform:
  ```hcl
  app_settings = {
    OTEL_EXPORTER_OTLP_ENDPOINT = var.otel_exporter_otlp_endpoint
    OTEL_EXPORTER_OTLP_PROTOCOL = "grpc"
    OTEL_TRACES_EXPORTER        = "otlp"
    OTEL_METRICS_EXPORTER       = "otlp"
    OTEL_LOGS_EXPORTER          = "otlp"
    DEPLOYMENT_ENV              = "production"
  }
  ```
  or Kubernetes:
  ```yaml
  env:
    - { name: OTEL_EXPORTER_OTLP_ENDPOINT, value: "http://otel-collector:4317" }
    - { name: OTEL_EXPORTER_OTLP_PROTOCOL, value: "grpc" }
    - { name: OTEL_TRACES_EXPORTER,  value: "otlp" }
    - { name: OTEL_METRICS_EXPORTER, value: "otlp" }
    - { name: OTEL_LOGS_EXPORTER,    value: "otlp" }
    - { name: DEPLOYMENT_ENV,        value: "production" }
  ```
  Print the ⚠ banner, show the stanza in the right syntax, name the exact file, and ask
  "Want me to add these to `<file>`? [y/N]". On yes, **merge into the existing resource/service
  block** — read the file, find the right block, add only the missing keys; never append a
  duplicate block. **Never invent the endpoint value**: leave it as a variable/placeholder the
  user fills, and say so.
- **`configFiles` empty or `endpointConfigured: null`** — no deployment file to write into. Print
  the ⚠ banner and the `KEY=value` list, and name where the settings go for this `host` (a Bicep
  `appSettings` block, a platform dashboard's app settings, a CI secret, etc.).

Then, for local development:
```
Locally, no collector required:
  OTEL_TRACES_EXPORTER=console npm start     # spans printed to stdout
Set OTEL_EXPORTER_OTLP_ENDPOINT to switch the exporters back to otlp.
```

Finally, if the subagent reported a wiring gap of its own — a serverless `host` where the
runtime delivers invocations over a non-HTTP channel, so `instrumentation-http` emits no SERVER
spans and a generated handler wrapper must be applied per route — repeat it here as an
unmissable, countable next step, e.g. "0 of 22 routes wrapped: instrumentation is present but
unreachable until `withServerSpan()` wraps each handler." Do not end the command reporting
success while the generated code is not actually reached.
