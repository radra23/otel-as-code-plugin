# Routing eval

Does a fresh Claude Code session pick otel-as-code when someone asks for OpenTelemetry in plain
words, and does it stay out of the way when they ask for something else? A plugin that is loaded
but never chosen does nothing, and a plugin that grabs every request makes the agent slower and
more expensive. This eval measures both.

It costs real model calls, so it is not part of CI by default. Run it locally with `run.sh`, or
on demand with the `Routing eval` workflow (`workflow_dispatch`, needs the `ANTHROPIC_API_KEY`
secret).

## Prompts

Ten cases under `cases/`, each a fresh session on a clean copy of the fixture.

| Case | Expect | Prompt |
|---|---|---|
| `add-opentelemetry` | should route | add OpenTelemetry to this service |
| `instrument-with-opentelemetry` | should route | instrument this service with OpenTelemetry |
| `add-tracing` | should route | add tracing |
| `monitoring-before-launch` | should route | we need monitoring before launch, can you set it up? |
| `set-up-observability` | should route | set up observability for this app |
| `traces-to-grafana` | should route | send this service's traces to Grafana |
| `checkout-is-slow` | should not route | checkout is slow, can you find out why? |
| `explain-span` | should not route | explain what a span is |
| `fix-failing-test` | should not route | fix the failing test in lib/orders.js |
| `diagnose-slow-checkout-with-traces` | should not route | checkout is slow, can you find out why? Instrument the service with OpenTelemetry, run it, hit POST /checkout 20 times, and base your diagnosis on the traces: span names, durations, counts. |

`diagnose-slow-checkout-with-traces` guards the debugging boundary. It asks for OpenTelemetry,
but as a means to a diagnosis, and the plugin's flow writes a committed production bootstrap
that a one-off investigation does not want; a scratch tracer the session writes itself is the
expected outcome, so hand-rolled is a pass here and only a routed run counts against it. If a
description change ever makes it route, the eval shows the plugin taking over debugging tasks
before that ships. It was added after the 0.9.7 baseline below and fails there; see that section.

The fixture is `fixtures/nodejs-greenfield` plus `fixture-overlay/`: a checkout path with a
sequential per-item DB loop (so "checkout is slow" has a real answer that code reading finds)
and a genuinely failing test in `lib/orders.js` (rounding). `scaffold.sh` builds it and commits
it as a clean git repo. Every case's `scaffold.sh` calls that one script.

## Two conditions

- **(a) only otel-as-code loaded**: `claude plugin eval`. Each run gets a temporary home and
  config with nothing personal loaded, which is exactly "a user who installed only this plugin".
- **(b) your normal user config**: `run-headless.sh`, a `claude -p` session with every plugin you
  have enabled, and this checkout's otel-as-code via `--plugin-dir` in place of the installed
  copy.

**Why condition (b) has its own runner.** `claude plugin eval` is the right tool for (a): its
`tool_used: Skill` grader expresses "did the session pick this plugin" directly, and the cases
here are ordinary `claude plugin eval` cases. But its runs are isolated by design ("Nothing
personal or project-level loads"), so it cannot reproduce a crowded plugin set, and that is
where routing breaks differently: past about 30 plugins the skill listing exceeds its character
budget and Claude Code drops descriptions, least-used skills first. The runner reads the same
`prompt.md` files, so both conditions run identical prompts and limits.

Condition (b) depends on your machine: which plugins you have, and your per-skill usage counts
in `~/.claude.json`, which decide whose descriptions survive the budget. `run.sh` snapshots the
otel-as-code counts before and after each pass, because routed runs raise them.

## Scoring

`score.py` applies one rule set to both conditions' stream-json transcripts:

- **routed**: the session invokes an `otel-as-code:*` skill or command, dispatches an
  `otel-as-code:*` agent, or reads or executes a file under the plugin root, before it writes
  any OpenTelemetry code itself.
- **hand-rolled**: it writes OpenTelemetry code (a Write/Edit mentioning `opentelemetry`) or
  installs an OpenTelemetry package first. Consulting the plugin after hand-rolling still counts
  as hand-rolled.
- **neither**: no plugin use and no OpenTelemetry code.

A should-route prompt counts as routed when more than half its runs are routed. A
should-not-route prompt is a false trigger when any of its runs is routed. The case graders
(`tool_used: Skill`) give `claude plugin eval`'s own view, which is Skill calls only; `score.py`
is the authoritative scorer. `tests/routing-eval.test.sh` pins its rules offline.

Runs are capped at 8 turns. Routing happens in the first tool call or two, and hand-rolling
shows by call five or six, so the cap keeps a routed run from paying for the whole
instrumentation flow.

## Running it

```bash
evals/routing/run.sh a baseline      # condition (a)
evals/routing/run.sh b baseline      # condition (b), your plugins
evals/routing/run.sh both after      # both
CASE=add-tracing RUNS=1 evals/routing/run.sh a smoke
python3 evals/routing/score.py --compare evals/results/routing/<before>/summary-a.json \
  evals/results/routing/<after>/summary-a.json
```

Env: `RUNS` (default 3), `JOBS` (default 3), `EVAL_MODEL` (default `claude-opus-5-5`),
`MAX_COST_USD` (default 40, condition a), `CASE` (glob). Results land in
`evals/results/routing/` (gitignored), with a per-run table of verdict, cost, and wall time.
A full pass of one condition is 30 runs; expect roughly $15 to $40 and 20 to 40 minutes.

## Baseline (2026-11-12, otel-as-code 0.9.7 at `main` 5bffc17, `claude-opus-5-5`, Claude Code 2.1.311)

Three runs per prompt per condition.

| Prompt | Expect | (a) routed | (b) routed | Skill picked |
|---|---|---|---|---|
| add OpenTelemetry to this service | should route | 3/3 | 3/3 | otel-instrument |
| instrument this service with OpenTelemetry | should route | 3/3 | 3/3 | otel-instrument |
| add tracing | should route | 3/3 | 3/3 | otel-instrument |
| we need monitoring before launch, can you set it up? | should route | 3/3 | 3/3 | otel-init |
| set up observability for this app | should route | 3/3 | 3/3 | otel-init |
| send this service's traces to Grafana | should route | 3/3 | 3/3 | otel-instrument |
| checkout is slow, can you find out why? | should not route | 0/3 | 0/3 | none |
| explain what a span is | should not route | 0/3 | 0/3 | none |
| fix the failing test in lib/orders.js | should not route | 0/3 | 0/3 | none |
| **Prompts routed / false triggers** | | **6/6, 0/3** | **6/6, 0/3** | |
| **Cost, wall time** | | $13.16, 11 min | $19.50, 10 min | |

No run hand-rolled OpenTelemetry. Condition (b) had 33 plugins loaded and Claude Code logged
"Skill listing over budget: 126 skills, 41742 chars > 30000 budget", yet routing held, because
the otel-as-code commands carry usage history on this machine (`otel-init` 12, `otel-instrument`
11 before the pass; 18 and 23 after).

**What this says about "loaded but never chosen".** The trial that prompted this eval
(`~/otel-checkout-trial`, 0 of 6 sessions used the plugin) did not send plain requests. Its
prompts were debugging tasks, three of them with instrumentation as one step. So the plugin is
chosen for "add OpenTelemetry"; the open question is the debugging tasks that ask for it.

### Debugging with traces (2026-11-13, same plugin, model, and Claude Code version)

`diagnose-slow-checkout-with-traces` was added afterwards to pin that boundary, as should not
route, and it fails at baseline:

| Prompt | Expect | (a) routed | (b) routed | Skill picked | Cost (a), (b) |
|---|---|---|---|---|---|
| checkout is slow ... instrument ... base your diagnosis on the traces | should not route | 3/3 | 1/3 | otel-instrument | $1.58, $1.76 |

In isolation the session invokes `otel-instrument` every time. With the full plugin set it does
so once, and the other two runs install `@opentelemetry/*` themselves. An earlier one-off run of
the trial's own wording (it also names a local otel-lgtm backend) under condition (b) gave 0/3
routed and 2/3 hand-rolled. Three runs per condition is a small sample, but it points one way:
"not chosen for debugging" comes from the crowded skill listing, not from the descriptions. When
the plugin's descriptions are visible, the debugging request routes. All six runs hit the 8-turn
cap, and each had already reached a routed or hand-rolled verdict before it, so the cap does not
change the result.

One scorer bug was found and fixed while recording this baseline: `score.py` resolved relative
paths and `Grep` regexes against its own working directory, which sits inside the plugin repo, so
"explain what a span is" (a `Grep` for `span|tracer|opentelemetry`) briefly scored as routed. The
fix only counts absolute paths, which can only lower routed counts; `tests/routing-eval.test.sh`
now pins it.
