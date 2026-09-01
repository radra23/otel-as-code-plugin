---
description: "First-run: scan the repo, detect service boundaries, and prime the context cache"
---

# /otel-init

First-run setup for otel-as-code. Run this before any other /otel-* command.
This command is safe to re-run; it will refresh the context cache if stale.

## Step 1: Check context cache freshness

**This step is the single source of truth for cache freshness.** Every other /otel-* command
says "apply the freshness rule from `/otel-init` Step 1" and means exactly this.

Read `.claude/otel-context.json` if it exists.

If it does not exist: print "○ No context cache found — running first scan..." and go to Step 2.

If `schemaVersion` is missing or lower than `"2"`: the cache predates the current schema.
Treat it as stale, but still pass it to the scanner as `priorContext` (Step 2) — the user-owned
fields carry over unchanged. Print
"↻ Context cache uses an older schema — re-scanning (your confirmed answers are preserved)."

Otherwise decide freshness from **service-identity inputs**, not from `HEAD`. A commit that
touched only application code cannot change service identity, and re-scanning on every commit
costs minutes per command for nothing.

1. Rebuild the candidate identity-input list:
   ```
   { git ls-files; git ls-files --others --exclude-standard; } \
     | grep -E '(^|/)(package\.json|pyproject\.toml|requirements\.txt|go\.mod|Cargo\.toml|pom\.xml|build\.gradle(\.kts)?|global\.json|Directory\.Packages\.props|[^/]+\.(csproj|fsproj|sln)|Dockerfile|host\.json|serverless\.yml|CODEOWNERS)$' \
     | sort
   ```
   If this set differs from `freshness.identityInputs` in the cache, the cache is STALE
   (a service was added or removed). This regex and the scanner's `identityInputs` (see
   `agents/repo-context-scanner.md`) are ONE contract and must stay in lockstep: the scanner
   must store exactly the paths this regex produces — no bare directories, no `.env`/CI files —
   or the two sets differ on every run and the cache can never be judged current. Compare the
   two as sorted sets, not by order.
2. Otherwise recompute the fingerprint over that same list and compare to
   `freshness.identityFingerprint`:
   ```
   git hash-object <the paths above> | sha256sum | cut -c1-16
   ```
   If it differs, the cache is STALE (a manifest changed). If it matches, the cache is CURRENT
   even when `HEAD` has moved.
3. If this is not a git repo (`git rev-parse` fails), fall back to `sha256sum` over the same
   paths; if that also fails, treat the cache as stale.

- If CURRENT: print "✓ Context cache is current (identity: <fingerprint>)" and skip to Step 4.
- If STALE: print "↻ Context cache is stale (<reason: new/removed manifest <path> | <path>
  changed>) — re-scanning, confirmed answers preserved..." and continue to Step 2.

## Step 2: Invoke repo-context-scanner

Dispatch the `otel-as-code:repo-context-scanner` subagent with the repo root as context.

The subagent has **no `Skill` tool**, so it cannot read `semconv-discipline` itself — pass it the
guidance explicitly, or it records `guidanceVersion: null` and guesses the high-cardinality list:
- `semconvVersion`: the `SEMCONV_VERSION` value from the `semconv-discipline` skill (read it here
  first — you, the command, can).
- `semconvGuidancePath`: `${CLAUDE_PLUGIN_ROOT}/skills/semconv-discipline/SKILL.md` (an absolute
  path the subagent can `Read` for the canonical high-cardinality list).

**If a cache already existed, pass its full contents as `priorContext`.** The scanner merges it
per the cache ownership contract in `agents/repo-context-scanner.md` — scanner-owned fields are
refreshed from disk, user-owned fields (`businessAttrs`, `confirmedAt`, `namespace`,
`deploymentEnvironment`, resolved conflicts, user-confirmed team/namespace) are carried over
verbatim. A refresh is a MERGE, never a replace. Writing a bare scan over a confirmed cache
silently discards every answer `/otel-business-attrs` collected, and the user is not told.

Wait for the JSON response. Never write a scanner response whose user-owned fields are empty
over a cache where they were not — if that happens the merge did not run; re-dispatch with
`priorContext` rather than writing the result.

If the subagent returns an empty `services` array:
- Print: "No services detected. Is this an application repository? Check the service
  detection rules in the otel-as-code docs."
- Exit.

## Step 3: Present detected service boundaries

Print a table. `Runtime` is shown next to `Language` because they answer different questions
and the difference decides what can be instrumented:

```
Detected services:
  #  Service Name       Language   Runtime   Framework   Root Dir    Confidence
  1  portal-web         nodejs     browser   vite        web/        0.97 (package.json#name)
  2  checkout-api       nodejs     node      express     api/        0.97 (package.json#name)
```

For any service with `instrumentable: false`, print its `instrumentableReason` beneath the
table so the exclusion is visible now rather than discovered later by /otel-instrument:

```
  ⓘ portal-web is not an instrumentation target: runtime is browser; browser/RUM
    instrumentation is out of scope for the MVP.
```

If there are any conflicts in the scanner response, show the conflict resolution block
from the `otel-as-code:business-attr-ux` skill for each conflict.

Ask: "Do these service boundaries look correct? [Y/n/edit]"

If the user types 'n' or 'edit':
- Show numbered list of services
- Ask: "Enter a number to rename/remove, or 'add' to add a service manually"
- Handle the edit inline; repeat until user confirms
- Mark any manually added service `"nameSource": "user-added"` so a later re-scan keeps it

## Step 4: Write outputs

Write `.claude/otel-services.json`:
```json
{
  "schemaVersion": "1",
  "generatedAt": "<ISO-8601>",
  "services": [ <confirmed service list> ]
}
```

Write `.claude/otel-context.json` with the full (merged) scanner JSON output.

**Update `.gitignore`.** `.claude/otel-context.json` and `.claude/.otel-force` are ephemeral and
must be ignored; `.claude/otel-services.json` is the shared service map and must stay
committable. Inspect the existing rules before adding anything, because a blanket ignore
silently swallows the service map and **git cannot un-ignore a file inside an excluded
directory** — the directory rule itself has to change:

- If `.gitignore` contains a blanket `.claude` or `.claude/` rule, that rule must be rewritten,
  not appended to. Tell the user what you found and what it costs, then rewrite it:
  ```
  ⚠ .gitignore:<line> ignores all of .claude/, so .claude/otel-services.json is ignored too.
    Git cannot un-ignore a file inside an excluded directory, so the directory rule has to
    become a contents rule plus a negation. Rewriting:
      -  .claude
      +  .claude/*
      +  !.claude/otel-services.json
  ```
  Do not apply the rewrite silently and do not leave it unmentioned — this is the user's
  ignore policy, and other tooling may depend on it.
- If there is no blanket rule, append the two specific paths if absent:
  `.claude/otel-context.json` and `.claude/.otel-force`.
- Do NOT add `.claude/otel-services.json` in either case — users should commit the service map.

## Step 5: Show recommended next steps

```
✓ otel-as-code initialized.

Recommended next steps:
  /otel-business-attrs   — confirm service identity and business attribute namespace
  /otel-instrument       — generate OTel SDK bootstrap code
  /otel-collector agent  — generate an OTel Collector config
  /otel-evaluate         — audit existing OTel coverage (brownfield repos)

Commit .claude/otel-services.json so your team shares the same service map.
```
