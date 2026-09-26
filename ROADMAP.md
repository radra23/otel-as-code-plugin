# Roadmap

> **Draft.** This is a direction, not a delivery commitment. There are no dates on purpose:
> the project is maintained in spare hours and a date I miss is worse than no date at all.
> Ordering within each section is soft and moves in response to what people actually ask for.
>
> Each section below maps to a [milestone](https://github.com/radra23/otel-as-code-plugin/milestones)
> of the same shape, and every concrete line item that isn't done yet has a linked tracking issue —
> comment there rather than only in this file if you want to weigh in.

Current release: **0.8.1**. Node.js, Python, Java, .NET, Go, and Ruby instrumentation, Terraform
for Grafana, Datadog, New Relic, and Dash0, semconv pinned at 1.44.0. Since 0.2.0 the command set
has grown past generation: `/otel-uninstrument` rolls instrumentation back behind an ownership
marker, `/otel-remediate` proposes a deployment-config diff for services that have no application
source to bootstrap, and `--dry-run` previews any writing command before it writes. Everything
shipped so far is tracked (closed) under the
[`0.1.0 MVP — shipped`](https://github.com/radra23/otel-as-code-plugin/milestone/4) milestone.

## Now: earning trust in what already ships — [milestone](https://github.com/radra23/otel-as-code-plugin/milestone/1)

Coverage is the tempting thing to work on, but breadth on top of output nobody has verified is
just a larger surface to be wrong on. So the near-term work is depth.

- **Validate the Terraform against live vendor accounts — partially proven.** An opt-in,
  dormant-until-configured CI job (`tf-live-validate.yml`) applies a golden module against a real
  vendor account, reads back the created resources to confirm the API actually accepted them, then
  destroys everything. **All four backends are now wired** — the matrix covers every vendor in
  `backends.txt`, and the offline gating test enforces that rather than trusting it. **Dash0 has
  run live**; its first run immediately caught a real bug offline `terraform validate` could never
  have caught. The other three stay dormant until accounts are configured — each skips cleanly, so
  the job is safe to run with any subset enabled. Grafana and New Relic each need one extra secret
  naming a pre-existing object (a Prometheus datasource UID, an entity GUID), both documented in
  `tests/tf-live/README.md` and both a real finding when they fail.
  [#121](https://github.com/radra23/otel-as-code-plugin/issues/121) now tracks getting the
  remaining three actually running. The README's "not yet proven against live vendor backends"
  caveat narrows or comes off as each backend joins Dash0 — wiring is not proof; a green run is.
- **Widen the fixture set.** Every generator bug found so far came from a codebase shape we had
  not met: a monorepo, a framework that hides the entry point, an unusual Python layout, a Blazor
  WASM app, a hostless .NET test project. Fixtures are cheaper than guesswork — see the
  `dogfooding-regression.test.sh` pattern that ties an authored classification rule to the fixture
  that exercises it, so a fix can't silently regress. Three shapes the prompts had rules for but
  nothing exercised are now covered: **azure-functions** (the serverless no-SERVER-span gap — the
  shape behind the worst field report, where the generated wrapper was imported by zero files),
  an **npm-workspaces monorepo** mixing a browser SPA with two node services (the pair that made
  `services[0]` the wrong default), **aws-lambda**, and **gcp-cloud-functions** — the last of
  which immediately earned its keep: the serverless guidance had lumped all three FaaS hosts
  together as having no inbound HTTP server, but the Node Functions Framework runs a real
  in-process Express server, so the prescribed wrapper would have emitted a second SERVER span
  per request. Exactly the roadmap's own argument for fixtures over guesswork. **Non-npm monorepo layouts
  are covered too** — pnpm (`services/*`), Go multi-module (`go.work`) and Maven multi-module
  (`<modules>`): member resolution previously existed only for npm `workspaces`, so each of
  those read as a single service (the aggregator or the repo root) while every real service went
  undetected. The Go fixture also pins the distinction that several `go.mod` files means several
  services while one module with `cmd/<name>` means one service with several binaries. Ongoing:
  [#122](https://github.com/radra23/otel-as-code-plugin/issues/122).
- **Keep the pins honest — and the guidance with them.** The weekly drift-check CI job reports
  staleness automatically and opens/closes a tracking issue on its own; acting on what it reports
  (bumping semconv, the SDKs, the Java agent, the providers) stays routine, manual work that keeps
  the output worth trusting. It also checks something a version comparison cannot: every OLD→NEW
  row in `semconv-discipline` is verified against the upstream attribute registry at the pinned
  tag, so a replacement that does not exist — or an attribute called deprecated that is still
  current — is caught while the pin itself looks perfectly fresh. That failure mode is the one
  that actually bit: confidently wrong guidance ages worse than an old pin, because nothing about
  it looks stale.

## Next: the coverage people ask for most — [milestone](https://github.com/radra23/otel-as-code-plugin/milestone/2)

- **More backends.** Driven by requests rather than by a list I made up. Open a
  [coverage request](https://github.com/radra23/otel-as-code-plugin/issues/new?template=03-coverage-request.yml)
  and say what you run; that is how ordering gets decided.
- **Collector topology beyond the basics — largely shipped.** Tail sampling (gateway mode: error /
  latency / debug / probabilistic policies) and the cardinality-guardrail OTTL transforms (agent
  mode, driven by what the scanner/auditor actually finds high-cardinality) both already generate.
  What's left in this space now lives under "Later" as a sharper ask — a real cost *budget*, not
  just deny-listing known-bad attributes.

## Later: toward v1 — [milestone](https://github.com/radra23/otel-as-code-plugin/milestone/3)

- **PHP and Rust.** Ruby shipped in 0.2.0 (proven end-to-end in CI) — no design work started on
  the remaining two yet.
  [#117](https://github.com/radra23/otel-as-code-plugin/issues/117) (PHP),
  [#118](https://github.com/radra23/otel-as-code-plugin/issues/118) (Rust).
- **Cardinality and cost budgets as generated policy**, not just as guardrail comments — a
  structural spend ceiling, distinct from the deny-list guardrails that already ship. The
  Collector is the right place to enforce it, and almost nobody does it, because writing the
  config by hand is tedious. That is exactly the kind of tedium a generator should absorb.
  Tracked: [#119](https://github.com/radra23/otel-as-code-plugin/issues/119).
- **Semconv migration assistance — shipped for the mechanical cases.**
  [#120](https://github.com/radra23/otel-as-code-plugin/issues/120) landed: `/otel-evaluate`
  reports deprecated attributes with stable finding IDs, and `/otel-instrument --fix <ids>` now
  generates the migration for rows the `semconv-discipline` table marks `mechanical` — a straight
  key rename. What is left is the `manual` class, where the value itself changes shape
  (`http.target` splitting into `url.path` + `url.query`, `http.host` carrying a port that
  `server.address` does not). Those are reported back as skipped, naming why, rather than guessed
  at — and a generator that reshapes values wrongly is worse than one that declines, so this stays
  deliberately unfinished until the reshaping can be proven per case.

## Not planned

Saying no in public saves everyone time.

- **Browser and RUM instrumentation.** `/otel-instrument` targets server-side runtimes. A
  browser SPA is detected and refused with a reason rather than handed a Node bootstrap that
  cannot run in a bundle. RUM is a genuinely different problem and it deserves a different tool.
- **Becoming a vendor's agent.** Backends are generated from the same vendor-neutral service
  model, and that is the point. If a feature only makes sense for one vendor's proprietary
  surface, it belongs in that vendor's tooling. All four supported backends now ship an official
  MCP server, and the answer there is the same: those are runtime tools that query a live account,
  while this plugin generates committed artifacts before one exists. They are worth using to
  *verify* generated output against a real account — never to generate it, which would route
  vendor-neutral output back through a single vendor. Any external source stays optional: the
  offline path has to keep working, because that is what CI validates against.
- **Replacing your IaC.** The generated Terraform is a reviewed starting point that you own
  after generation. It is not a module to depend on, and there will be no registry release.

## How to influence this list

Open a [coverage request](https://github.com/radra23/otel-as-code-plugin/issues/new?template=03-coverage-request.yml)
with the shape of your actual setup, or start a thread in
[Ideas](https://github.com/radra23/otel-as-code-plugin/discussions/categories/ideas).

Reports that something already shipped is wrong outrank requests for something new. A generator
that is trusted on four backends beats one that is doubted on ten.
