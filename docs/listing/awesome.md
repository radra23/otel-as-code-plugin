# Awesome-list submissions for otel-as-code

Project: https://github.com/radra23/otel-as-code-plugin

Facts used (checked 2026-11-14 against README.md and the GitHub API):

- Claude Code plugin with 9 commands, plus 10 Codex skills in `.agents/skills/`.
- Generates SDK bootstrap for Node.js, Python, Java (zero-code agent config), .NET, Go, Ruby, Rust (axum, actix-web); an otelcol-contrib Collector config (agent or gateway); Terraform (dashboard, alerts, SLO) for Grafana, Datadog, New Relic, Dash0.
- `/otel-local` runs `grafana/otel-lgtm` in Docker so the first trace, log and metric show up locally.
- Apache-2.0 (GitHub detects it). First commit 2026-06-20, 225 commits, latest release v0.11.1 on 2026-11-14, 1 star.

Fix before submitting anything (applies to every list below):

1. The GitHub repo description is out of date. It says "instrument Node.js/Python", but the README lists seven languages. Bots and reviewers read that description. Suggested replacement: `Claude Code plugin and Codex skills that generate vendor-neutral OpenTelemetry: SDK bootstrap for 7 languages, Collector config, and Terraform for Grafana, Datadog, New Relic and Dash0.` (It also contains an em dash and an ampersand you may want gone.)
2. The README demo GIF is still commented out (`docs/demo.gif`). No list below requires one, but a reviewer deciding in a few seconds benefits from it.

---

## 1. awesome-claude-code (hesreallyhim)

- Repo: https://github.com/hesreallyhim/awesome-claude-code
- Activity: 57,976 stars, not archived, last push 2026-11-14. Recent "Add resource" merges on 2026-10-22 (Review Inbox, Molecular Animation), 2026-10-19 (Cubicle Crew), 2026-10-18 (prismantis). Resource issues are processed daily (several closed 2026-11-11 and 2026-11-12, most as "not planned").
- Other Claude Code lists seen and not drafted: jqueryscript/awesome-claude-code (551 stars) and composio-community/awesome-claude-plugins (1,994 stars). Both are active; hesreallyhim is the canonical one.

Rules followed:

- CONTRIBUTING.md: https://github.com/hesreallyhim/awesome-claude-code/blob/main/CONTRIBUTING.md
- Issue form: https://github.com/hesreallyhim/awesome-claude-code/blob/main/.github/ISSUE_TEMPLATE/recommend-resource.yml

Submission method: **web UI issue form only.** No PRs. The `gh` CLI cannot submit it. The recommendation must be made by a human, not by an agent. Opening a PR or skipping the form risks a temporary block from the repo. The description below was drafted with an AI assistant: read it, and rewrite it in your own words where it does not sound like you, before you paste it.

Form link: https://github.com/hesreallyhim/awesome-claude-code/issues/new?template=recommend-resource.yml

Eligibility:

- Needs either 14+ days since the first commit with continued development, or 100+ stars. The project meets the age rule (first commit 2026-06-20, active through 2026-11-14). It does not meet the star rule (1 star). Age is enough.
- One resource at a time. Do not have another open recommendation.
- Description: 1 to 3 sentences, 10 to 500 characters, descriptive rather than promotional, does not address the reader, one line, no emojis.
- The maintainer says the list is selective, best effort, and favours resources specific to Claude Code. Most recent submissions were closed "not planned", so treat acceptance as uncertain.

Category: **Infrastructure & DevOps**. That section already lists otelcol-doctor (an OpenTelemetry Collector config skill) and terraform-skill, so it is where OTel and Terraform generators sit. The "Observability & Monitoring" sections are for observing Claude Code sessions themselves, which this project does not do.

Overlap check: otelcol-doctor covers Collector configs only. otel-as-code generates SDK bootstrap, Collector config and backend Terraform from one service model, so it is distinct. Not already on the list (searched for "otel-as-code").

Fields to paste:

| Field | Value |
|---|---|
| Title (pre-filled prefix) | `[Resource]: otel-as-code` |
| Display Name | `otel-as-code` |
| Category | `Infrastructure & DevOps` |
| Link | `https://github.com/radra23/otel-as-code-plugin` |
| Author Name | `radra23` (GitHub profile name is "Joana Carvalho"; use whichever you prefer) |
| Author Link | `https://github.com/radra23` |
| Description | see below |

Description (484 characters, one line, three sentences):

```
Plugin that scans a repo, detects its services, and generates vendor-neutral OpenTelemetry from one service model: SDK bootstrap for Node.js, Python, Java (agent config), .NET, Go, Ruby and Rust, an otelcol-contrib Collector config, and Terraform for dashboards, alerts and SLOs on Grafana, Datadog, New Relic or Dash0. Hooks block overwrites of generated files and lint semantic-convention names on every write. /otel-local starts a local Grafana stack in Docker for the first trace.
```

Checklist: tick the first five boxes only after doing what they say (visit the list yourself, check the links, read CONTRIBUTING.md). **Leave the sixth box unchecked.** It is a trap that marks the submitter as not reading.

---

## 2. magsther/awesome-opentelemetry

- Repo: https://github.com/magsther/awesome-opentelemetry
- Activity: 992 stars, not archived, last push 2026-11-07. Merged PRs: LogBrew and Cognipeer Agent SDK (2026-11-07), batch merges of 10 additions plus several single entries (2026-10-31), including PR #79 which created the "Coding Agent Skills" section. Five open PRs from 2026-11-10 to 2026-11-14, so new PRs get batch-reviewed every week or two.

Rules followed:

- contributing.md: https://github.com/magsther/awesome-opentelemetry/blob/main/contributing.md (an unfilled awesome-list template: no concrete rules beyond the Code of Conduct and "edit your PR rather than opening a new one").
- Code of conduct: https://github.com/magsther/awesome-opentelemetry/blob/main/code-of-conduct.md
- No PR template and no lint workflow. Format taken from existing entries: `- [Name](url) - Description.`, appended at the end of the section.

Submission method: **pull request** editing `readme.md` (fork, branch, PR). PR title in the style of merged ones: `Add otel-as-code to Coding Agent Skills`.

Target section: **OpenTelemetry Instrumentation > Coding Agent Skills** (currently one entry, OllyGarden Agent Skills). Add the line directly after the OllyGarden entry.

Entry line:

```
- [otel-as-code](https://github.com/radra23/otel-as-code-plugin) - Claude Code plugin and Codex skills that scan a repo and generate vendor-neutral OpenTelemetry from one service model: SDK bootstrap for Node.js, Python, Java (agent config), .NET, Go, Ruby and Rust, an otelcol-contrib Collector config, and Terraform for Grafana, Datadog, New Relic and Dash0. Includes semconv linting on write and a local Grafana stack for the first trace.
```

Suggested PR body:

```
Adds otel-as-code to Coding Agent Skills. It is a Claude Code plugin with Codex skills that generates SDK bootstrap (7 languages), Collector config and backend Terraform from a scan of the repo. Distinct from the OllyGarden entry, which gives agents OTel knowledge; this one generates the files and checks them in CI. Apache-2.0.
```

No age or star rule is stated.

---

## 3. adriannovegil/awesome-observability

Not OpenTelemetry-only, but a large, active observability list with OTel tooling sections, so it is included.

- Repo: https://github.com/adriannovegil/awesome-observability
- Activity: 750 stars, not archived, last push 2026-11-07. Nine of the last ten closed PRs were merged on 2026-11-06 and 2026-11-07 (LogBrew, spantruth, Cognipeer Observability, ros2_pulse, and others). Open PRs from 2026-11-12 and 2026-11-13.

Rules followed:

- contributing.md: https://github.com/adriannovegil/awesome-observability/blob/master/contributing.md
- PR template: https://github.com/adriannovegil/awesome-observability/blob/master/.github/pull_request_template.md
- Lint workflow (runs on every PR): https://github.com/adriannovegil/awesome-observability/blob/master/.github/workflows/lint.yml (lychee link check plus `awesome-lint@2.3.0`). `make lint` runs both in Docker.

Rules that matter here:

- One resource per PR, in the most relevant section.
- Format: `- [Name](https://example.com/) - Short, factual description.` Neutral language, canonical HTTPS URL, no tracking parameters.
- Excluded: "very early projects without enough information for readers to evaluate them." The project is pre-1.0 (v0.11.1), but the README documents what CI proves per language, so it should clear this.
- awesome-lint: description starts with a capital letter and ends with a period; no URL already used elsewhere in the README.

Submission method: **pull request** against `master`, editing `README.md`, with the PR template filled.

Target section: **6. Collector > Configuration & Linters**. That section already holds generators and checkers for Collector config (Augur, OpenTelemetry Collector Recipes, zeroreads), and generated Collector config is one of the three outputs. Alternative: **3. Collect > Tracing**, which is thin (two entries) and fits the SDK-bootstrap side. Pick one; do not add to both (awesome-lint flags double links).

Entry line:

```
- [otel-as-code](https://github.com/radra23/otel-as-code-plugin) - Claude Code plugin and Codex skills that generate OpenTelemetry SDK bootstrap for seven languages, an otelcol-contrib agent or gateway config, and Terraform for Grafana, Datadog, New Relic and Dash0 from a scan of the repo, with semantic-convention linting on every write.
```

PR template, filled:

```
## Summary

- Adds otel-as-code to Collector > Configuration & Linters. Claude Code plugin and Codex skills that generate OTel SDK bootstrap, Collector config and backend Terraform from one service model. Apache-2.0.

## Checklist

- [x] I added or changed one resource per pull request when possible.
- [x] The resource is in the most relevant section.
- [x] The description is short, factual, and neutral.
- [x] The link is canonical, public, and works.
- [x] I ran `make lint` locally when possible.
```

Only tick the last box if you actually ran `make lint` (needs Docker).

---

## Lists checked and dropped

| List | Stars | Last push | Why dropped |
|---|---|---|---|
| [SigNoz/Awesome-OpenTelemetry](https://github.com/SigNoz/Awesome-OpenTelemetry) | 38 | 2026-05-01 | Three PRs merged on 2026-05-01 after no merges since 2022-08. Open PRs from 2026-08-27 and 2026-10-18 sit unreviewed. Outside the 6-month window and not reviewing. |
| [deeloc206/awesome-opentelemetry](https://github.com/deeloc206/awesome-opentelemetry) | 3 | 2026-05-04 | One merged PR ever, no activity for 6 months, almost no audience. |
| [MadVikingGod/awesome-opentelemetry](https://github.com/MadVikingGod/awesome-opentelemetry) | 0 | 2021-05-26 | Inactive since 2021. |
| [sairamgopi1972/awesome-opentelemetry-Public](https://github.com/sairamgopi1972/awesome-opentelemetry-Public) | 1 | 2025-02-26 | Inactive for over a year. |

## Rules the project may not yet meet

- awesome-claude-code: 1 star, below the 100-star route, but the 14-day age route is met. The submission must be made by you in the web form, not by an agent or the `gh` CLI. Acceptance is at the maintainer's discretion and most recent submissions were closed "not planned".
- awesome-observability: "very early projects" can be refused. The project is pre-1.0 with 1 star; the README's CI-proof tables are the evidence to point to if asked.
- No list requires a demo GIF, but the README's GIF is still commented out.
- The GitHub repo description is stale (Node.js/Python only). Fix it first.
