---
name: semconv-discipline
description: OpenTelemetry semantic-convention rules — resource vs span attributes, HTTP/DB/messaging attribute names, deprecations, custom-namespace prefixing, and cardinality limits. Apply when writing, generating, or reviewing OTel instrumentation code.
---

# semconv-discipline (Codex bridge)

Read and apply `skills/semconv-discipline/SKILL.md` at the repo root — the single source of
truth for OTel semantic-convention rules and the pinned `SEMCONV_VERSION`.

In Codex this partly substitutes for the plugin's `semconv-lint` hook (which does not auto-fire
here): consult it proactively whenever you touch OTel instrumentation code, and check generated
output against its rules before writing.
