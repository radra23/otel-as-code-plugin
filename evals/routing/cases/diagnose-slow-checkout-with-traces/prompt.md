---
tags: [routing, should-not-route]
max_turns: 8
timeout_seconds: 600
allowed_tools: [Read, Glob, Grep, Skill, Agent, TodoWrite]
---
checkout is slow, can you find out why? Instrument the service with OpenTelemetry, run it, hit POST /checkout 20 times, and base your diagnosis on the traces: span names, durations, counts.
