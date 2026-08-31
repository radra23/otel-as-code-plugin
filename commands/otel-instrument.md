---
description: Generate OTel SDK bootstrap and OTLP wiring for this service
argument-hint: "[language] [--service <id>] [--fix <ids>] [--experimental] [--force]"
---

# /otel-instrument [language] [--service <id>] [--fix <ids>] [--experimental] [--force]

Generate OTel SDK bootstrap and OTLP wiring for one service.

## Flags
- `[language]` — optional; `nodejs`, `python`, or `java`. If omitted, derived from the
  selected service (Step 2). It narrows the candidate services; it does not pick one.
- `--service <id>` — the service to instrument, by `id` from the context JSON. Skips the
  Step 2 prompt.
- `--fix <ids>` — apply only the findings with these IDs from the most recent
  `/otel-evaluate` report (e.g. `--fix SC-2,SH-1`). Scopes regeneration to those findings
  instead of rewriting whole files. See Step 5.
- `--experimental` — unlock pre-Stable signals (e.g. logs for Python). Passed to
  both `language-maturity` and `semconv-discipline` skills.
- `--force` — overwrite existing generated artifacts. Required if the write-guard hook blocks
  a re-generation. **`--force` is a full regeneration and discards hand edits** — read the
  warning in Step 4 before using it.

## Step 1: Load context

Read the `otel-as-code:language-maturity` skill — apply all maturity gating rules.

Check `.claude/otel-context.json`. Apply the freshness rule from `/otel-init` Step 1
(identity-input fingerprint, not `HEAD`). If stale or absent:
- Run `/otel-init` logic inline — dispatch `otel-as-code:repo-context-scanner` **passing the
  existing cache as `priorContext`** so confirmed answers survive, and write what it returns.
  A refresh is a merge, never a replace (see `agents/repo-context-scanner.md`).
- Do NOT print the /otel-init success message; just run the scan silently.

## Step 2: Select the target SERVICE

Pick a service first; its language follows from it. Resolving a language alone settles nothing
when two services share one — and `services[0]` is not a safe default, because the first
detected service is frequently a browser SPA whose `language` is `nodejs` and whose runtime
is not Node at all.

1. Build the candidate list: every service in `context.services` with
   `instrumentable: true`. If `[language]` was given, keep only services with that `language`.
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
3. Validate the chosen service before generating. If it has `instrumentable: false`, refuse:
   ```
   ⚠ <name> cannot be instrumented by this command: <instrumentableReason>
     Generating a Node SDK bootstrap for a browser bundle produces code that cannot run and
     that breaks the build. Nothing was written.
   ```
   Exit. Emitting wrong code is worse than emitting none — do not fall back to a near-match.
4. Derive `language` from the selected service. If it is not `nodejs`, `python`, or `java`:
   - Print: "⚠ <language> is not supported yet. Supported: nodejs, python, java.
     v1 will add: go, dotnet, ruby, php, rust."
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
- `existingArtifacts`: the paths resolved in Step 4
- `preserve`: the current content of each file being overwritten, when `--force` was used
- `fixList`: when `--fix <ids>` was given, the findings with those IDs from the most recent
  `/otel-evaluate` report — each with its `file`, `line`, and required change. With a
  `fixList`, the subagent edits only those sites and leaves the rest of each file alone;
  it does not regenerate the file.

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

## Step 7: Deployment wiring — say what is still required

Print the subagent's summary, then this block. **Do not omit it and do not soften it.** The
generated bootstrap reads `OTEL_EXPORTER_OTLP_ENDPOINT` and hard-codes nothing, which is
correct — and it means the service exports nowhere until the deployment sets it. The generated
code defaults every exporter to `none` when no endpoint is configured, so the failure mode is
silence rather than a retry loop against `localhost:4317`; that is a safe default, not a
working one.

Use `service.deployment.configFiles` and `service.deployment.endpointConfigured` from the
context to make this concrete rather than generic:

- **`endpointConfigured: true`** — print one line confirming where it is set, and move on.
- **`endpointConfigured: false` and `configFiles` is non-empty** — name the exact files, and
  offer to write the settings:
  ```
  ⚠ Not done yet: no OTLP endpoint is configured for this deployment.
    Until one is set, every exporter defaults to "none" and this service emits nothing
    in the deployed environment.

    Deployment config found: infra/main.tf (azurerm_linux_function_app app_settings)
    Required settings:
      OTEL_EXPORTER_OTLP_ENDPOINT = <your collector or vendor endpoint>
      OTEL_EXPORTER_OTLP_PROTOCOL = grpc
      OTEL_TRACES_EXPORTER  = otlp
      OTEL_METRICS_EXPORTER = otlp
      OTEL_LOGS_EXPORTER    = otlp

    Want me to add these to infra/main.tf? [y/N]
  ```
  If the user accepts, write them into that file. This is the highest-impact gap in the whole
  flow: an instrumented service with no endpoint costs money and produces nothing.
- **`configFiles` empty or `endpointConfigured: null`** — say so plainly and list where the
  settings usually go for this `host` (Terraform `app_settings`, a Bicep `appSettings` block, a
  k8s `env:` / ConfigMap, `docker-compose.yml` `environment:`, a platform dashboard).

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
