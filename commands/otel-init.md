---
description: "First-run: scan the repo, detect service boundaries, and prime the context cache"
argument-hint: "[--local-ignore]"
---

# /otel-init [--local-ignore]

First-run setup for otel-as-code. Run this before any other /otel-* command.
This command is safe to re-run; it will refresh the context cache if stale.

## Flags
- `--local-ignore` — write the ignore rules for `.claude/otel-context.json` and
  `.claude/.otel-force` to `.git/info/exclude` instead of the tracked `.gitignore` (#212). Use
  this when evaluating someone else's repo, or any repo with a policy that nothing may be
  committed or left dirty: `.git/info/exclude` is honoured by git exactly like `.gitignore` but
  lives inside `.git/` — it is never tracked, never shows up in `git status`, and never needs
  committing or reverting. Without this flag the rules go into the tracked `.gitignore`, as
  before.

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

1. Rebuild the candidate identity-input list. Exclude vendored/dependency directories FIRST — a
   committed `node_modules` (common despite a `.gitignore` entry; `pnpm install` can put 300+
   `package.json` files under it) or `vendor`/`.venv` puts hundreds of paths the scanner never
   intended as identity inputs into this set, and every dependency bump then changes the
   fingerprint and marks the cache stale for reasons that have nothing to do with service
   identity (#187). **Then exclude test projects and tooling-only manifests (#208)** — a unit
   test `*.csproj`/`*.fsproj`, or anything under a `tests/`/`Tests/` directory, defines no
   service identity; a repo whose test suite changes on every commit should not pay for a
   full re-scan on every commit either. Two fixed default patterns, plus whatever this repo's
   own `.claude/otel-services.json` adds under `identityExclude` (an array of ERE fragments,
   same alternation syntax as the two defaults — e.g. a root `pyproject.toml`/`requirements.txt`
   that only configures pytest/lint, not a real service, needs a repo-specific pattern the
   defaults can't guess):
   ```
   EXCLUDE='(^|/)[^/]*[Tt]ests?\.(csproj|fsproj)$|(^|/)[Tt]ests?/'
   if [ -f .claude/otel-services.json ]; then
     USER_EXCLUDE=$(python3 -c "import json,sys; d=json.load(open('.claude/otel-services.json')); print('|'.join(d.get('identityExclude',[])))")
     [ -n "$USER_EXCLUDE" ] && EXCLUDE="$EXCLUDE|$USER_EXCLUDE"
   fi
   { git ls-files; git ls-files --others --exclude-standard; } \
     | grep -vE '(^|/)(node_modules|vendor|\.?venv|bin|obj)/' \
     | grep -E '(^|/)(package\.json|pnpm-workspace\.yaml|pyproject\.toml|requirements\.txt|setup\.py|go\.mod|go\.work|Cargo\.toml|Gemfile|composer\.json|pom\.xml|build\.gradle(\.kts)?|settings\.gradle(\.kts)?|global\.json|Directory\.Packages\.props|[^/]+\.(csproj|fsproj|sln)|([^/]+\.)?Dockerfile(\.[^/]+)?|host\.json|serverless\.yml|CODEOWNERS)$' \
     | grep -vE "$EXCLUDE" \
     | sort
   ```
   `identityExclude` is additive — it adds to the two defaults, never replaces them (a repo
   fixing its root-manifest case should not have to re-declare the test-project patterns too).
   If this set differs from `freshness.identityInputs` in the cache, the cache is STALE
   (a service was added or removed, OR `identityExclude` itself changed — recompute before
   comparing, never compare against a set built with a stale exclude list). This regex and the
   scanner's `identityInputs` (see `agents/repo-context-scanner.md`) are ONE contract and must
   stay in lockstep: the scanner must store exactly the paths this regex produces — no bare
   directories, no `.env`/CI files, nothing under a vendored directory the exclusion above drops,
   and nothing matching the exclude pattern above (defaults + this repo's own
   `identityExclude`) — or the two sets differ on every run and the cache can never be judged
   current. Compare the two as sorted sets, not by order.
2. Next, check that the fingerprint actually covers every service. The fingerprint only sees files
   matched by the regex above, so a service with none of them has nothing that can change it. A
   deployment-only workload (an upstream binary configured by a Kubernetes manifest, Helm
   values, or Terraform) is the common case, and a GitOps/config-only repo can have none of these
   files at all. There the stored and recomputed sets are both `[]`, the fingerprint is a hash
   of nothing, and without this check the cache would read as current forever, however much the
   deployment config changed (#150).
   An in-scope service (`inScope: true`) is **uncovered** when no `identityInputs` path other than
   `CODEOWNERS` is at or under its `rootDir`. A path is under `rootDir` when it equals it or starts
   with `<rootDir>/`, and `rootDir: "."` covers every path. `CODEOWNERS` maps owners and says
   nothing about how a service is built or deployed, so it doesn't count. If any in-scope service
   is uncovered, or `identityInputs` is empty, the cache is STALE. Re-scanning such a service is
   cheap, since there is little source to read. Don't try to fix this by adding deployment
   files to `identityInputs`: the regex can't reproduce them, so the sets would never match (#30).
3. Otherwise recompute the fingerprint over that same list and compare to
   `freshness.identityFingerprint`:
   ```
   git hash-object <the paths above> | sha256sum | cut -c1-16
   ```
   If it differs, the cache is STALE (a manifest changed). If it matches, the cache is CURRENT
   even when `HEAD` has moved.
4. If this is not a git repo (`git rev-parse` fails), fall back to `sha256sum` over the same
   paths; if that also fails, treat the cache as stale.

- If CURRENT: print "✓ Context cache is current (identity: <fingerprint>)" and skip to Step 4.
- If STALE: print "↻ Context cache is stale (<reason: new/removed manifest <path> | <path>
  changed | service <id> has no identity manifest, so its deployment config is always
  re-checked>) — re-scanning, confirmed answers preserved..." and continue to Step 2.

## Step 2: Invoke repo-context-scanner

Dispatch the `otel-as-code:repo-context-scanner` subagent with the repo root as context.

The subagent has **no clock, no way to read `plugin.json`, and no `Skill` tool** — pass all
three explicitly, or it invents a midnight timestamp, an eight-version-stale literal, and guesses
the high-cardinality list:
- `scanTime`: run `date -u +%Y-%m-%dT%H:%M:%SZ` and pass its output. Without this the subagent
  stamps `scannedAt` and every `observedAt`/`derivedAt` from the schema's `<ISO-8601>` example,
  which reads as the date at midnight — making two same-day scans indistinguishable (#202).
- `pluginVersion`: read the `version` field from `${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json`
  and pass it. Without this the subagent stamps `pluginVersion` from the schema's `0.1.0` example
  literal, so a cache written today claims a release eight-plus minor versions old (#177).
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

Wait for the JSON response, then hand it to `scripts/write_context.py` in Step 4 — that script,
not this step, is what refuses to write a result whose user-owned fields went empty over a cache
where they were not (#211). If it refuses, the merge did not run; re-dispatch with `priorContext`
rather than trying to patch the JSON by hand before retrying the write.

**Empty scan (the shared rule).** If the subagent returns an empty `services` array — or a
cache you loaded already has `services: []`:
- Print: "No services detected. Is this an application repository? Check the service
  detection rules in the otel-as-code docs."
- **Write nothing and exit 0.** In particular do NOT write the scan to `.claude/otel-context.json`:
  the `.gitignore` update below lives in Step 4, which an empty scan never reaches, so a cache
  written here is left as an untracked file in the user's repo.
- `/otel-evaluate`, `/otel-instrument`, `/otel-collector` and `/otel-backend` apply this same rule
  right after they load or refresh the context (#164), and it overrides their "write what it
  returns" instruction for a scan with no services. They reference it rather than restate it,
  because a repo with no application service has nothing to audit, instrument, collect from, or
  build a dashboard for, and each of them used to fail differently: a vacuous "no instrumentation
  detected" that points back at a command that cannot help, an empty candidate list with no
  reason, and a module built for a placeholder service.

## Step 3: Present detected service boundaries

Print a table. `Runtime` is shown next to `Language` because they answer different questions
and the difference decides what can be instrumented:

```
Detected services:
  #  Service Name       Language   Runtime   Framework   Root Dir    Confidence
  1  portal-web         nodejs     browser   vite        web/        0.97 (package.json#name)
  2  checkout-api       nodejs     node      express     api/        0.97 (package.json#name)
```

For any service that is not `generatorSupported` (or is `inScope: false`), print its
`instrumentableReason` beneath the table so the exclusion — and the difference between "out of
scope" (`inScope: false`, e.g. a browser bundle) and "in scope but no generator yet"
(`generatorSupported: false, inScope: true`, e.g. an already-instrumented .NET service you can
still audit with `/otel-evaluate`) — is visible now rather than discovered later:

```
  ⓘ portal-web is not an instrumentation target: runtime is browser; browser/RUM
    instrumentation is out of scope for the MVP.
```

If there are any conflicts in the scanner response, show the conflict resolution block
from the `otel-as-code:business-attr-ux` skill for each conflict.

**If any service's `derived.notes` suggests test/tooling evidence (#207)** — a test-project
marker, a `tests/`/`perf/`/`tools/` root, or a perf/benchmark-style name — flag it right under
the table, distinct from the `instrumentableReason` block above (this is a suggestion on an
`inScope: true` service, not an existing exclusion):
```
  ⚠ perf-harness looks like test/tooling (IsTestProject=true), not a production service. Still
    in scope today — exclude it below if it's not something to instrument/monitor.
```

Ask: "Do these service boundaries look correct? [Y/n/edit]"

If the user types 'n' or 'edit':
- Show numbered list of services
- Ask: "Enter a number to rename/remove, 'exclude <N>' to mark it out of scope permanently
  (survives re-scans — for test/tooling the scanner flagged, or anything else that isn't a real
  service), or 'add' to add a service manually"
- `exclude <N>` sets that service's `scopeOverride: "out"` — write it into `context.json` as a
  user-owned field (see the scanner's cache ownership contract) so it survives the NEXT re-scan,
  unlike hand-editing `inScope` itself, which is scanner-owned and gets silently overwritten.
- Handle the edit inline; repeat until user confirms
- Mark any manually added service `"nameSource": "user-added"` so a later re-scan keeps it

## Step 4: Write outputs

Write `.claude/otel-services.json`. Run `date -u +%Y-%m-%dT%H:%M:%SZ` and use its actual output for
`generatedAt` — do not copy the placeholder below literally, that produces midnight every time:
```json
{
  "schemaVersion": "1",
  "generatedAt": "<the real output of date -u +%Y-%m-%dT%H:%M:%SZ>",
  "services": [ <confirmed service list> ]
}
```

**Write `.claude/otel-context.json` via `scripts/write_context.py` (#211) — never by transcribing
the scanner's JSON into a `Write` call by hand.** The scanner's response is the full JSON string
from Step 2; pipe it to the script on stdin rather than retyping it, since a hand transcription of
~10 KB is exactly where a field gets silently dropped, reordered, or truncated:

```bash
echo '<the scanner's raw JSON response, verbatim>' | python3 "${CLAUDE_PLUGIN_ROOT}/scripts/write_context.py" \
  --output .claude/otel-context.json \
  --existing .claude/otel-context.json \
  --plugin-root "${CLAUDE_PLUGIN_ROOT}"
```

The script re-derives, in code, the same checks this step used to ask the model to hold in its
head while copying: it refuses (nonzero exit, nothing written) if the new JSON would empty a
user-owned field the existing cache had non-empty, if `services` would go from non-empty to empty
(#164 — pass `--allow-empty-services` only after confirming the deletion with the user), or if
`scannedAt`/`pluginVersion` look invented rather than real (#177/#202). On refusal, do not retry by
loosening a check — the refusal means Step 2 needs to be redone with the real `priorContext`,
`scanTime`, or `pluginVersion`, not that the write step is wrong. Every other command that
refreshes the cache invokes this same script the same way; they cross-reference this step rather
than restating the invocation.

**Update the ignore rules.** `.claude/otel-context.json` and `.claude/.otel-force` are ephemeral
and must be ignored; `.claude/otel-services.json` is the shared service map and must stay
committable.

**Target file: `.gitignore` by default, `.git/info/exclude` with `--local-ignore` (#212).** The
two files are interchangeable to git — both are plain gitignore-syntax pattern lists, and a file
matching a rule in *either* is ignored — but only `.gitignore` is tracked. `--local-ignore` exists
for a repo where nothing may be committed or left dirty (someone else's repo, or one under a
strict change policy): with it, write the two rules below to `.git/info/exclude` instead, which
git honours identically but which lives inside `.git/` and is never tracked, never shows up in
`git status`, and never needs committing. Say which file you used either way.

Inspect the existing rules in the TARGET file before adding anything, because a blanket ignore
silently swallows the service map and **git cannot un-ignore a file inside an excluded
directory** — the directory rule itself has to change:

- If the target file contains a blanket `.claude` or `.claude/` rule, that rule must be
  rewritten, not appended to. Tell the user what you found and what it costs, then rewrite it:
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
  **Exception with `--local-ignore`:** if the blanket rule is in the TRACKED `.gitignore` (not
  `.git/info/exclude`), do not rewrite it — editing a tracked file is exactly what `--local-ignore`
  was asked to avoid. Warn instead, and say the cache files are covered by `.git/info/exclude` but
  `.claude/otel-services.json` is still swallowed by the tracked rule until the user fixes it
  themselves.
- If there is no blanket rule in the target file, append the two specific paths if absent:
  `.claude/otel-context.json` and `.claude/.otel-force`.
- Do NOT add `.claude/otel-services.json` to either file — users should commit the service map.

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
