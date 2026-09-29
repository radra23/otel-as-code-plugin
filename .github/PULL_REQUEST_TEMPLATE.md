## Summary

<!-- What this changes and why. "Closes #123" if it closes an issue. -->

## What changed

<!-- Optional. The reasoning a reviewer cannot infer from the diff; skip it if the summary already carries that. -->

## Test plan

<!--
The most useful section here: what you ran, and what it proved. A reviewer should be able to
reproduce it without guessing — "ran /otel-instrument against fixtures/python-greenfield, the
generated tracing.py now emits service.namespace".

CI already asserts --strict, the test suites, the Terraform snapshots, the bootstrap pins, the
Codex bridge and the plugin.json version bump, so spend this section on what CI cannot see:
the thing you reproduced by hand, the teeth-check that proves a new test actually fails when
the rule it guards is removed.
-->

- [ ] Vendor, SDK and semantic-convention facts were verified against the source, not recalled — linked where it isn't obvious.
- [ ] Nothing hardcoded that has a single source of truth (`SEMCONV_VERSION`, `backends.txt`, `hooks/otel-paths.sh`).
