# Security policy

## Reporting a vulnerability

Please report privately through
[GitHub Security Advisories](https://github.com/radra23/otel-as-code-plugin/security/advisories/new)
rather than opening a public issue. You will get an acknowledgement within a few days.

This is a small project maintained in spare hours, so please do not expect a same-day response.
You will get an honest one.

## Supported versions

Only `main` is supported. The project is pre-1.0 and there is no backport branch.

## What is in scope

otel-as-code is a code generator that runs inside your agent session, so the interesting surface
is not a running service. It is these three things:

**Generated artifacts.** A bug that makes the generated SDK bootstrap, Collector config, or
Terraform leak credentials, disable TLS, send telemetry somewhere unintended, or grant broader
vendor permissions than the module claims. This is the highest-value category. Telemetry is
plumbing that runs everywhere in a fleet, and a bad default propagates quietly.

**The guardrail hooks.** `write-guard` refuses to overwrite files you have hand-edited, and the
`--force` sentinel is how you deliberately override that. Anything that lets a write slip past
the guard without the sentinel, or that makes the sentinel match a path it should not, is a
security issue and not just a bug. Path normalisation across host conventions is the sharp edge
here, and it is where we would most like extra eyes.

**The context cache.** `.claude/otel-context.json` is ephemeral and gitignored;
`.claude/otel-services.json` is meant to be committed. Anything that puts a credential,
endpoint, or account identifier into the committed file is in scope.

## What is out of scope

Vulnerabilities in OpenTelemetry itself, in the Terraform providers, or in your observability
vendor. Report those upstream. We will happily help you work out where a finding belongs if it
is not obvious.

## A note on the generated Terraform

The backend modules are validated for syntax and schema in CI, not applied against live vendor
accounts. Review the plan before you apply, the same as you would for any module you did not
write yourself. That is a documented limitation rather than a vulnerability, but it is worth
saying plainly in the same place you would look for the security policy.
