---
description: Generate OTel SDK bootstrap and OTLP wiring for this service
argument-hint: "[language] [--experimental] [--force]"
---

# /otel-instrument [language] [--experimental] [--force]

Generate OTel SDK bootstrap and OTLP wiring for this service.

## Flags
- `[language]` — optional; `nodejs`, `python`, or `java`. If omitted, detected from context JSON.
- `--experimental` — unlock pre-Stable signals (e.g. logs for Python). Passed to
  both `language-maturity` and `semconv-discipline` skills.
- `--force` — overwrite existing generated artifacts (tracing.js / tracing.py / otel-java.env).
  Required if the write-guard hook blocks a re-generation.

## Step 1: Load context

Read the `otel-as-code:language-maturity` skill — apply all maturity gating rules.

Check `.claude/otel-context.json`. If absent or stale (gitHash mismatch, or a dirty working
tree affecting service identity — apply the freshness rule from `/otel-init` Step 1):
- Run `/otel-init` logic inline (dispatch repo-context-scanner, write cache).
  Do NOT print the /otel-init success message; just run the scan silently.

## Step 2: Determine target language

If `[language]` argument was given, use it.
Otherwise use `context.services[0].language` (first detected service).

If language is not `nodejs`, `python`, or `java`:
- Print: "⚠ <language> is not supported yet. Supported: nodejs, python, java.
  v1 will add: go, dotnet, ruby, php, rust."
- Exit.

Note: `java` uses the OpenTelemetry Java **agent** (zero-code auto-instrumentation), so the
generated artifact is `otel-java.env` + run instructions, not a source bootstrap file. The
`instrumentation-gen` subagent handles the per-language artifact shape.

## Step 3: Check signal maturity

For the target language, apply the maturity gate rules from `language-maturity` skill.

If any signal is Development-level AND `--experimental` is NOT set:
- Print the Development-level warning from the skill.
- Do not generate that signal's code.
- Print: "Re-run with --experimental to generate Development-level signals."

## Step 4: Check for existing artifact

Look for `tracing.js` (Node.js), `tracing.py` (Python), or `otel-java.env` (Java) in the service root.

If found AND `--force` is NOT set:
- Print: "⚠ Generated artifact already exists: <path>. Use --force to overwrite."
- Exit.

If found AND `--force` IS set:
- Print: "↻ Overwriting existing artifact (--force)."
- Authorize the overwrite for the `write-guard` hook by listing the absolute path(s) the
  subagent will overwrite (the existing `tracing.js` / `tracing.py` / `otel-java.env` in the
  service root) in the `.claude/.otel-force` sentinel, one per line. A slash-command flag
  cannot set an env var for the hook process, so this file is how `--force` reaches the guard.
  Run, e.g.:
  `mkdir -p .claude && printf '%s\n' "<abs path of tracing.js / tracing.py / otel-java.env>" >> .claude/.otel-force`
  (use the service's `rootDir` from the context JSON to build the absolute path).

## Step 5: Dispatch instrumentation-gen subagent

Pass to `otel-as-code:instrumentation-gen`:
- `context`: the loaded context JSON
- `language`: resolved language
- `experimental`: boolean from --experimental flag
- `service`: the target service object from context

## Step 6: Confirm completion

The subagent handles file writing and prints its summary.
After it returns, print the next-steps block from the subagent's output.

If a `.claude/.otel-force` sentinel was created in Step 4, remove it now so the write-guard
is restored for subsequent writes: `rm -f .claude/.otel-force`.
