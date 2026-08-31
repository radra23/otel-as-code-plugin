# Contributing to otel-as-code

Thanks for looking. This project is small enough that a single good issue moves it, so there is
no contribution too minor to be worth your time.

## The fastest way to help

You do not have to write code. In rough order of how much they help:

1. **Run it against a real repo and tell us what came out.** The generators are only as good as
   the variety of codebases they have met. A `package.json` shape we have never seen, a Python
   project laid out unusually, a Dockerfile that hides the entry point: every one of those is a
   bug we cannot find on our own. Open an *Incorrect generated output* issue, or post the run in
   [Show and tell](https://github.com/radra23/otel-as-code-plugin/discussions/categories/show-and-tell).
2. **Tell us a semantic convention we got wrong.** With a link to the spec section, this is
   usually a one-commit fix.
3. **Ask for a language or backend**, and say what your setup actually looks like. The concrete
   case is what determines whether generated output is useful rather than merely present.
4. **Fix a typo.** Genuinely welcome. Small PRs are easy to merge and they are how most people
   start.

## Getting set up

```bash
git clone https://github.com/radra23/otel-as-code-plugin
cd otel-as-code-plugin
claude --plugin-dir .          # hot-reloads as you edit
```

For Codex, make this repo your working directory and invoke a workflow with `$otel-init`.

Try a change against the fixtures before you try it against your own code. `fixtures/` holds a
greenfield Node.js service, a greenfield Python one, a Java one, and a deliberately messy
brownfield Node.js service with seeded semconv violations. That last one is the useful test
subject: it is what a real codebase looks like after three years.

## How the repo is put together

Read [`CLAUDE.md`](CLAUDE.md) before your first change. It is short, and it holds the
architecture decisions that are not obvious from the file tree. The two-minute version:

- **Nothing is registered by hand.** Commands, agents, skills, and hooks are auto-discovered
  from `commands/*.md`, `agents/*.md`, `skills/<name>/SKILL.md`, and `hooks/hooks.json`.
  `.claude-plugin/plugin.json` is metadata only. Add a file in the right place with the right
  frontmatter and it exists.
- **Several things have exactly one source of truth**, and duplicating them is the mistake this
  codebase is most prone to:

  | Fact | Lives in |
  |---|---|
  | Semconv spec version | `SEMCONV_VERSION` in `skills/semconv-discipline/SKILL.md` |
  | Supported vendor list | `backends.txt` |
  | Which paths the plugin generates | `hooks/otel-paths.sh` |
  | Context-cache schema and ownership | `agents/repo-context-scanner.md` |

  If you find yourself typing a vendor name or a version into a second file, stop and read
  `CLAUDE.md`. There is almost certainly a list you should be reading from instead. A
  hand-maintained parallel list is how `telemetry.ts` once shipped past the write guard.

- **Codex is a bridge, not a fork.** `.agents/skills/` and `.codex/hooks.json` point back at the
  same canonical `commands/`, `skills/`, `agents/`, and `hooks/*.sh`. Rename something and the
  bridge needs updating. CI checks that the references resolve, so you will hear about it.

## Running the tests

```bash
bash tests/hooks/write-guard.test.sh
bash tests/hooks/semconv-lint.test.sh
bash tests/hooks/session-summary.test.sh
bash tests/hooks/codex-adapters.test.sh
bash tests/drift-check.test.sh
bash tests/snapshots/instrument/pins.test.sh
claude plugin validate . --strict
```

One shell caveat that costs people an afternoon: GitHub Actions runs `run:` blocks as
`bash -eo pipefail`. If you are on macOS, your shell is zsh, and zsh does not word-split
unquoted `$VAR`. Reproduce CI logic in bash or you will chase a difference that is not in your
change.

## Changing generated output

This is the part with real teeth, because the output is what people ship.

Terraform golden snapshots live in `tests/snapshots/<vendor>/main.tf.snap`. CI runs
`terraform validate` on each one against the real provider, which catches schema breaks. **CI
does not diff regenerated output against the snapshots**, so content drift is on you: when you
intentionally change generation, regenerate, copy the result over the snapshot, and read the
diff yourself. `tests/snapshots/README.md` has the exact commands, and
`tests/check-snapshots.sh` is a local helper for the regenerate-and-compare loop.

For the SDK bootstraps, `tests/snapshots/instrument/pins.test.sh` guards the pinned package
versions and the syntax. The end-to-end job in `tests/e2e/` is the one that proves telemetry
actually arrives: a generated bootstrap exporting through a generated Collector config into a
running trace store, asserted on every push.

When you change an attribute, check it against the
[semantic conventions](https://opentelemetry.io/docs/specs/semconv/) rather than against what
looks reasonable, and link the section in your PR. "Looks reasonable" is how a fleet ends up
with `http.method` three years after it was deprecated.

## Commits and PRs

Conventional commits (`feat:`, `fix:`, `docs:`, `test:`, `chore:`), with the area in parens when
it helps: `fix(instrument): ...`. Keep PRs to one concern. The PR template asks how a reviewer
can verify your result, and that section is the one worth spending a minute on.

Draft PRs are welcome, including ones that do not work yet. It is easier to help with a broken
branch than with a description of a broken branch.

## Where to ask

Questions go in [Discussions](https://github.com/radra23/otel-as-code-plugin/discussions), not
issues. "Am I doing this right?" is a completely reasonable thing to ask there, and the answer
stays findable for the next person.

## Code of conduct

By participating you agree to the [Code of Conduct](CODE_OF_CONDUCT.md). It says be decent, at
length.
