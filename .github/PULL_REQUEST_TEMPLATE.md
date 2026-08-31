## What this changes

<!-- One or two sentences. If it fixes an issue, "Fixes #123" here. -->

## Why

<!-- The reasoning a reviewer cannot infer from the diff. -->

## Checklist

- [ ] `claude plugin validate . --strict` passes.
- [ ] Tests for anything I touched run clean locally (`bash tests/hooks/*.test.sh`, and the relevant `tests/` scripts).
- [ ] I did not hardcode a value that has a single source of truth: `SEMCONV_VERSION` lives in `skills/semconv-discipline/SKILL.md`, the vendor list in `backends.txt`, the generated-path set in `hooks/otel-paths.sh`.

### If this changes generated output

- [ ] Terraform snapshots regenerated and reviewed (`tests/snapshots/<vendor>/main.tf.snap`, see `tests/snapshots/README.md`).
- [ ] Bootstrap pins still pass `tests/snapshots/instrument/pins.test.sh`.
- [ ] I checked the change against the semantic conventions rather than against what looked reasonable, and linked the spec section if it is not obvious.

### If this renames or moves a command, skill, agent, or hook

- [ ] The Codex bridge still resolves (`.agents/skills/`, `.codex/hooks.json`, `hooks/codex/`).

## How you can verify it

<!--
The single most useful thing in a PR here. A reviewer should be able to reproduce your result
without guessing. For example: "ran /otel-instrument against fixtures/python-greenfield,
the generated tracing.py now emits service.namespace; before/after diff below."
-->
