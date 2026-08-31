# Roadmap

> **Draft.** This is a direction, not a delivery commitment. There are no dates on purpose:
> the project is maintained in spare hours and a date I miss is worse than no date at all.
> Ordering within each section is soft and moves in response to what people actually ask for.

Current release: **0.1.0 (MVP)**. Node.js and Python instrumentation, Java via the agent,
Terraform for Grafana, Datadog, New Relic, and Dash0, semconv pinned at 1.44.0.

## Now: earning trust in what already ships

Coverage is the tempting thing to work on, but breadth on top of output nobody has verified is
just a larger surface to be wrong on. So the near-term work is depth.

- **Validate the Terraform against live vendor accounts.** Today every backend module is
  `terraform validate`d in CI against the real provider schema, which catches a schema break but
  proves nothing about whether the dashboard renders or the alert fires. This is the single
  biggest gap between what the README promises and what the README can prove. Closing it means
  ephemeral accounts and a `plan`/`apply` job, and the honest note in the README comes off the
  day it lands.
- **Widen the fixture set.** Every generator bug found so far came from a codebase shape we had
  not met: a monorepo, a framework that hides the entry point, an unusual Python layout.
  Fixtures are cheaper than guesswork.
- **Keep the pins honest.** The weekly drift check reports; acting on it is manual. Bumping
  semconv, the SDKs, the Java agent, and the providers is routine work that keeps the output
  worth trusting.

## Next: the coverage people ask for most

- **Go and .NET instrumentation.** The two most requested runtimes after what already ships, and
  the two with the most mature upstream story.
- **More backends.** Driven by requests rather than by a list I made up. Open a coverage issue
  and say what you run; that is how ordering gets decided.
- **Collector topology beyond the basics.** Tail sampling, and the OTTL transforms that turn a
  cardinality problem into a bounded one before it reaches your bill.

## Later: toward v1

- **Ruby, PHP, and Rust.**
- **Cardinality and cost budgets as generated policy**, not just as guardrail comments. The
  Collector is the right place to enforce a spend ceiling, and almost nobody does it, because
  writing the config by hand is tedious. That is exactly the kind of tedium a generator should
  absorb.
- **Semconv migration assistance.** `/otel-evaluate` already finds deprecated attributes. The
  natural next step is generating the migration rather than reporting the gap.

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
