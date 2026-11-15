---
name: why-is-it-slow
description: Find out why part of a running app is slow, times out, fails only sometimes, or spikes. Adds a few timing spans around the suspect code, runs it against a local trace viewer on this machine, and explains the cause from the measured evidence. Use when the user describes a speed or reliability symptom in plain words ("checkout is slow", "login times out sometimes", "this endpoint spikes"). Not for a test that fails every time, a crash with a stack trace, or a slow build.
version: 0.1.0
---

# Why is it slow?

The user described a symptom in their own words. Answer it with measurements, not by reading the
code and guessing: run the `otel-as-code:otel-why` command with their words as the symptom.

- Invoke it through the Skill tool: `otel-as-code:otel-why`, with the args set to the user's
  symptom in quotes, plus `--route "<METHOD> <path>"` if they named the request.
- Then follow that command step by step. It is the single source of the procedure: find the code,
  add 2 to 5 probes, use the local stack, read the traces with `scripts/trace_summary.py`, and
  show the evidence before the interpretation.

If the user explicitly asks for a quick look at the code instead of a measurement, do that, and
say that it is a reading of the code, not measured evidence.
