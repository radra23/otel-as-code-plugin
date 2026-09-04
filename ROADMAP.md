# Roadmap

> **Draft.** This is a direction, not a delivery commitment. There are no dates on purpose:
> the project is maintained in spare hours and a date I miss is worse than no date at all.
> Ordering within each section is soft and moves in response to what people actually ask for.
>
> Each section below maps to a [milestone](https://github.com/radra23/otel-as-code-plugin/milestones)
> of the same shape, and every concrete line item that isn't done yet has a linked tracking issue —
> comment there rather than only in this file if you want to weigh in.

Current release: **0.2.0**. Node.js, Python, Java, and .NET instrumentation, Terraform for
Grafana, Datadog, New Relic, and Dash0, semconv pinned at 1.44.0. Everything shipped so far is
tracked (closed) under the
[`0.1.0 MVP — shipped`](https://github.com/radra23/otel-as-code-plugin/milestone/4) milestone.

## Now: earning trust in what already ships — [milestone](https://github.com/radra23/otel-as-code-plugin/milestone/1)

Coverage is the tempting thing to work on, but breadth on top of output nobody has verified is
just a larger surface to be wrong on. So the near-term work is depth.

- **Validate the Terraform against live vendor accounts — partially proven.** An opt-in,
  dormant-until-configured CI job (`tf-live-validate.yml`) applies a golden module against a real
  vendor account, reads back the created resources to confirm the API actually accepted them, then
  destroys everything. **Dash0 is wired and has run live** — its first run immediately caught a
  real bug offline `terraform validate` could never have caught. New Relic's leg exists in code but
  has no account configured yet; Grafana and Datadog aren't wired in at all.
  [#121](https://github.com/radra23/otel-as-code-plugin/issues/121) tracks broadening this. The
  README's "not yet proven against live vendor backends" caveat narrows or comes off as each
  backend joins Dash0.
- **Widen the fixture set.** Every generator bug found so far came from a codebase shape we had
  not met: a monorepo, a framework that hides the entry point, an unusual Python layout, a Blazor
  WASM app, a hostless .NET test project. Fixtures are cheaper than guesswork — see the
  `dogfooding-regression.test.sh` pattern that ties an authored classification rule to the fixture
  that exercises it, so a fix can't silently regress. Ongoing:
  [#122](https://github.com/radra23/otel-as-code-plugin/issues/122).
- **Keep the pins honest.** The weekly drift-check CI job reports staleness automatically and
  opens/closes a tracking issue on its own; acting on what it reports (bumping semconv, the SDKs,
  the Java agent, the providers) stays routine, manual work that keeps the output worth trusting.

## Next: the coverage people ask for most — [milestone](https://github.com/radra23/otel-as-code-plugin/milestone/2)

- **Go instrumentation.** The remaining most-requested runtime — .NET, its former pairing in this
  list, shipped in 0.2.0 (proven end-to-end in CI). Go has no equivalent to Node's `require -r`,
  Python's import-time instrumentation, or .NET's DI-container extension method, so this needs its
  own design pass (manual SDK wiring vs. the eBPF-based zero-code agent) before generation work
  starts. Tracked: [#115](https://github.com/radra23/otel-as-code-plugin/issues/115).
- **More backends.** Driven by requests rather than by a list I made up. Open a
  [coverage request](https://github.com/radra23/otel-as-code-plugin/issues/new?template=03-coverage-request.yml)
  and say what you run; that is how ordering gets decided.
- **Collector topology beyond the basics — largely shipped.** Tail sampling (gateway mode: error /
  latency / debug / probabilistic policies) and the cardinality-guardrail OTTL transforms (agent
  mode, driven by what the scanner/auditor actually finds high-cardinality) both already generate.
  What's left in this space now lives under "Later" as a sharper ask — a real cost *budget*, not
  just deny-listing known-bad attributes.

## Later: toward v1 — [milestone](https://github.com/radra23/otel-as-code-plugin/milestone/3)

- **Ruby, PHP, and Rust.** No design work started on any of the three yet.
  [#116](https://github.com/radra23/otel-as-code-plugin/issues/116) (Ruby),
  [#117](https://github.com/radra23/otel-as-code-plugin/issues/117) (PHP),
  [#118](https://github.com/radra23/otel-as-code-plugin/issues/118) (Rust).
- **Cardinality and cost budgets as generated policy**, not just as guardrail comments — a
  structural spend ceiling, distinct from the deny-list guardrails that already ship. The
  Collector is the right place to enforce it, and almost nobody does it, because writing the
  config by hand is tedious. That is exactly the kind of tedium a generator should absorb.
  Tracked: [#119](https://github.com/radra23/otel-as-code-plugin/issues/119).
- **Semconv migration assistance.** `/otel-evaluate` already finds deprecated attributes and
  reports them with stable finding IDs. The natural next step is generating the migration (via the
  existing `--fix <ids>` mechanism) rather than only reporting the gap.
  Tracked: [#120](https://github.com/radra23/otel-as-code-plugin/issues/120).

## Not planned

Saying no in public saves everyone time.

- **Browser and RUM instrumentation.** `/otel-instrument` targets server-side runtimes. A
  browser SPA is detected and refused with a reason rather than handed a Node bootstrap that
  cannot run in a bundle. RUM is a genuinely different problem and it deserves a different tool.
- **Becoming a vendor's agent.** Backends are generated from the same vendor-neutral service
  model, and that is the point. If a feature only makes sense for one vendor's proprietary
  surface, it belongs in that vendor's tooling.
- **Replacing your IaC.** The generated Terraform is a reviewed starting point that you own
  after generation. It is not a module to depend on, and there will be no registry release.

## How to influence this list

Open a [coverage request](https://github.com/radra23/otel-as-code-plugin/issues/new?template=03-coverage-request.yml)
with the shape of your actual setup, or start a thread in
[Ideas](https://github.com/radra23/otel-as-code-plugin/discussions/categories/ideas).

Reports that something already shipped is wrong outrank requests for something new. A generator
that is trusted on four backends beats one that is doubted on ten.
