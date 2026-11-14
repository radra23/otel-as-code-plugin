# Listing otel-as-code

Drafts for listing the plugin outside this repo. Nothing here has been submitted; every step
below is yours to do by hand.

| File | For |
|---|---|
| [plugin-directory.md](plugin-directory.md) | Anthropic's plugin directory: submitted and refused by policy (see its Outcome section); the portal steps, answers, security facts, routing-eval evidence |
| [otel-registry.yml](otel-registry.yml) and [otel-registry-steps.md](otel-registry-steps.md) | The OpenTelemetry Registry entry and how to open the PR (the registry is frozen right now; read the steps file first) |
| [awesome.md](awesome.md) | awesome-claude-code, awesome-opentelemetry and awesome-observability, each in its own required format |

## GitHub repo settings (Settings, then the gear next to About)

**Description** (the current one says "Node.js/Python" and has an em dash):

```text
Claude Code plugin and Codex skills that add OpenTelemetry to your services in 7 languages, show your first trace on a local Grafana stack, and generate Terraform for Grafana, Datadog, New Relic and Dash0.
```

**Website:** `https://github.com/radra23/otel-as-code-plugin#readme` (or leave empty).

**Topics.** Keep the 15 you have (claude-code, claude-code-plugin, codex, dash0, datadog, grafana,
instrumentation, new-relic, observability, observability-as-code, opentelemetry, otel, semconv,
telemetry, terraform) and add these 5, which brings it to GitHub's limit of 20:
`tracing`, `opentelemetry-collector`, `monitoring`, `code-generation`, `ai-agents`.

## Checklist, in order

1. Merge the `chore/listing-ready` PR, so 0.11.2 (manifest metadata, icon wiring, the README
   section on what the plugin runs) is on `main`.
2. Update the repo description and topics above:
   https://github.com/radra23/otel-as-code-plugin
3. Optional but worth it before any human reviewer looks: record the demo
   ([docs/demo/README.md](../demo/README.md)) and uncomment the image lines at the top of the README.
4. Anthropic plugin directory: **submitted 2026-11-14 and refused by directory policy** (command
   hooks and scripts are accepted only from Verified organizations); not listed, by decision.
   See the outcome at the top of [plugin-directory.md](plugin-directory.md). The original step:
   follow [plugin-directory.md](plugin-directory.md) at
   https://claude.ai/directory/manage (needs a paid plan and the GitHub account that can push to the
   repo). Use a contact email you read, not the GitHub no-reply address.
5. awesome-claude-code: the web issue form only, submitted by you, one recommendation at a time:
   https://github.com/hesreallyhim/awesome-claude-code/issues/new?template=recommend-resource.yml
   ([awesome.md](awesome.md), section 1; leave the sixth checkbox unticked).
6. awesome-opentelemetry: a PR adding one line under "Coding Agent Skills":
   https://github.com/magsther/awesome-opentelemetry ([awesome.md](awesome.md), section 2).
7. awesome-observability: a PR against `master` with the template filled, one section only:
   https://github.com/adriannovegil/awesome-observability ([awesome.md](awesome.md), section 3).
8. OpenTelemetry Registry: wait. It is frozen
   (https://github.com/open-telemetry/opentelemetry.io/issues/11377). Sign the CNCF CLA now if you
   like, and when it reopens, write the entry and PR description yourself (their first-PR AI policy)
   using [otel-registry.yml](otel-registry.yml) as the reference, per
   [otel-registry-steps.md](otel-registry-steps.md).
