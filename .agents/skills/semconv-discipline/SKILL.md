---
name: semconv-discipline
description: OpenTelemetry semantic-convention rules — resource vs span attributes, HTTP/DB/messaging attribute names, deprecations, custom-namespace prefixing, and cardinality limits. Apply when writing, generating, or reviewing OTel instrumentation code.
---

# semconv-discipline (Codex bridge)

Read and apply `skills/semconv-discipline/SKILL.md` at the repo root — the single source of
truth for OTel semantic-convention rules and the pinned `SEMCONV_VERSION`.

In Codex, `.codex/hooks.json` runs `semconv-lint` as a PostToolUse advisory on OTel file writes;
consult this skill proactively too so output is conformant before it is written.
