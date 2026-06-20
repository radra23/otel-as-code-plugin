# /otel-init

First-run setup for otel-as-code. Run this before any other /otel-* command.
This command is safe to re-run; it will refresh the context cache if stale.

## Step 1: Check context cache freshness

Read `.claude/otel-context.json` if it exists.

If it exists:
- Get current git HEAD: run `git rev-parse HEAD`
- Compare the `gitHash` field in the JSON to the current HEAD.
- ALSO check whether the working tree is dirty in a way that affects service identity —
  a matching HEAD does not guarantee a fresh scan if identity inputs changed since the
  last commit. Run:
  `git status --porcelain -- '*package.json' '*pyproject.toml' '*go.mod' '*pom.xml' '*build.gradle' '*Dockerfile' 'CODEOWNERS' '.github/CODEOWNERS'`
  and treat any newly added service directory as identity-affecting too.
- The cache is CURRENT only if BOTH hold: the `gitHash` matches HEAD AND that status output
  is empty.
  - If current: print "✓ Context cache is current (git: <hash>)" and skip to Step 4.
  - If the hash differs OR identity files are dirty: print
    "↻ Context cache is stale (<reason: commit changed | uncommitted changes to <files>>) — re-scanning..."
    and continue to Step 2.
- If this is not a git repo (`git rev-parse` fails): the cache cannot be verified, so treat
  it as stale and re-scan.

If it does not exist: print "○ No context cache found — running first scan..."

## Step 2: Invoke repo-context-scanner

Dispatch the `otel-as-code:repo-context-scanner` subagent with the repo root as context.
Wait for its JSON response.

If the subagent returns an empty `services` array:
- Print: "No services detected. Is this an application repository? Check the service
  detection rules in the otel-as-code docs."
- Exit.

## Step 3: Present detected service boundaries

Print a table:

```
Detected services:
  #  Service Name       Language   Framework   Root Dir    Confidence
  1  checkout-api       nodejs     express     .           0.97 (package.json#name)
  2  worker             nodejs     unknown     worker/     0.70 (dir name)
```

If there are any conflicts in the scanner response, show the conflict resolution block
from the `otel-as-code:business-attr-ux` skill for each conflict.

Ask: "Do these service boundaries look correct? [Y/n/edit]"

If the user types 'n' or 'edit':
- Show numbered list of services
- Ask: "Enter a number to rename/remove, or 'add' to add a service manually"
- Handle the edit inline; repeat until user confirms

## Step 4: Write outputs

Write `.claude/otel-services.json`:
```json
{
  "schemaVersion": "1",
  "generatedAt": "<ISO-8601>",
  "services": [ <confirmed service list> ]
}
```

Write `.claude/otel-context.json` with the full scanner JSON output.

Update `.gitignore`: add `.claude/otel-context.json` and `.claude/.otel-force` if not present
(both are ephemeral — the context cache and the transient `--force` sentinel).
Do NOT add `.claude/otel-services.json` — users should commit the service map.

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
