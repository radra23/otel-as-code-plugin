# infra-only-repo

The shape from #164: an infrastructure repository with no application service. One OpenTofu
stack, docs, and a directory of one-shot Python scripts whose only manifest is a one-line
`requirements.txt`. No web framework, no entry point a process manager would start, no Dockerfile.

The scanner is expected to return `services: []` for it, and every command that needs a service
must then say what `/otel-init` says and write nothing, instead of dead-ending, printing an empty
candidate list, or building a module for a placeholder service.
