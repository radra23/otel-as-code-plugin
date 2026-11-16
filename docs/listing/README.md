# Listing otel-as-code

Drafts for listing the plugin outside this repo, and where each submission stands. Status checked
2026-11-16: the plugin directory refused it by policy, the awesome-opentelemetry and
awesome-observability PRs are open, and awesome-claude-code and the OpenTelemetry Registry are not
submitted yet. Every submission is yours to make by hand.

| File | For |
|---|---|
| [plugin-directory.md](plugin-directory.md) | Anthropic's plugin directory: submitted and refused by policy (see its Outcome section); the portal steps, answers, security facts, routing-eval evidence |
| [otel-registry.yml](otel-registry.yml) and [otel-registry-steps.md](otel-registry-steps.md) | The OpenTelemetry Registry entry and how to open the PR (the registry is frozen right now; read the steps file first) |
| [awesome.md](awesome.md) | awesome-claude-code, awesome-opentelemetry and awesome-observability, each in its own required format |

## GitHub repo settings (Settings, then the gear next to About)

**Description** (same claim as the README's first line; 246 characters, GitHub allows 350):

```text
OpenTelemetry set up for you by your coding agent (Claude Code plugin, Codex skills): checked as it is written, proven in CI, and your first trace on your own machine today. Dashboards and alerts as code for Grafana, Datadog, New Relic and Dash0.
```

**Website:** `https://github.com/radra23/otel-as-code-plugin#readme` (or leave empty).

**Topics.** Keep the 15 you have (claude-code, claude-code-plugin, codex, dash0, datadog, grafana,
instrumentation, new-relic, observability, observability-as-code, opentelemetry, otel, semconv,
telemetry, terraform) and add these 5, which brings it to GitHub's limit of 20:
`tracing`, `opentelemetry-collector`, `monitoring`, `code-generation`, `ai-agents`.

## Checklist, in order

1. Done: the `chore/listing-ready` PR merged (#239), so the manifest metadata, icon wiring and the
   README section on what the plugin runs are on `main` (now at 0.23.0).
2. Done (checked 2026-11-16): the repo description and all 20 topics above are set:
   https://github.com/radra23/otel-as-code-plugin
3. Optional but worth it before any human reviewer looks: record the demo
   ([docs/demo/README.md](../demo/README.md)) and uncomment the image lines at the top of the README.
4. Anthropic plugin directory: **submitted 2026-11-14 and refused by directory policy** (command
   hooks and scripts are accepted only from Verified organizations); not listed, by decision.
   See the outcome at the top of [plugin-directory.md](plugin-directory.md). The original step:
   follow [plugin-directory.md](plugin-directory.md) at
   https://claude.ai/directory/manage (needs a paid plan and the GitHub account that can push to the
   repo). Use a contact email you read, not the GitHub no-reply address.
5. awesome-claude-code: not submitted yet. The web issue form only, submitted by you, one
   recommendation at a time:
   https://github.com/hesreallyhim/awesome-claude-code/issues/new?template=recommend-resource.yml
   ([awesome.md](awesome.md), section 1; leave the sixth checkbox unticked).
6. awesome-opentelemetry: PR open, waiting for review:
   https://github.com/magsther/awesome-opentelemetry/pull/105 ([awesome.md](awesome.md), section 2).
7. awesome-observability: PR open since 2026-11-14; its lint workflow waits for maintainer approval:
   https://github.com/adriannovegil/awesome-observability/pull/222 ([awesome.md](awesome.md), section 3).
8. OpenTelemetry Registry: wait. It is frozen
   (https://github.com/open-telemetry/opentelemetry.io/issues/11377). Sign the CNCF CLA now if you
   like, and when it reopens, write the entry and PR description yourself (their first-PR AI policy)
   using [otel-registry.yml](otel-registry.yml) as the reference, per
   [otel-registry-steps.md](otel-registry-steps.md).
