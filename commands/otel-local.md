---
description: "See this service's traces, logs and metrics on your machine: start a free local Grafana stack (grafana/otel-lgtm) in Docker and point the service at it. Not for diagnosing one slow or failing request."
argument-hint: "[--service <id>] [--force] [--dry-run] [--down]"
---

# /otel-local [--service <id>] [--force] [--dry-run] [--down]

Give a developer with no observability background their first trace, log and metric on their own
machine, with no vendor to choose and nothing leaving the machine. Starts `grafana/otel-lgtm` (one
container: an OpenTelemetry Collector, Tempo, Loki, Prometheus, Pyroscope and Grafana) and writes
the env wiring that points one service at it.

It writes two files, both carrying the ownership marker:
- `otel-local.compose.yaml` at the repo root: the stack. One per repo, shared by every service.
- `otel-local.env` in the service's `rootDir`: the endpoint wiring for that service.

**Deployed environments do not change.** The generated bootstraps keep defaulting every exporter
to `none` when no endpoint is set. `otel-local.env` is loaded only by the explicit command this
command prints, and its name deliberately does not start with `.env`, so dotenv, Next.js, Vite and
similar loaders never pick it up. A deployed build never sees it.

## Flags
- `--service <id>`: the service to wire. Otherwise selected as `/otel-instrument` Step 2 does.
- `--force`: overwrite an existing, marker-carrying `otel-local.compose.yaml` / `otel-local.env`
  that differs from what would be generated (hand edits are lost). Same sentinel mechanism as
  `/otel-collector` Step 3.
- `--dry-run`: decide the ports and print both files (or a diff against the existing ones), then
  stop. Writes nothing, starts nothing, exits non-zero if a file would change.
- `--down`: stop the stack and offer to remove the two files (Step 8). Nothing else runs.

The pinned image is **`grafana/otel-lgtm:0.40.0`**. This line is the single source of the tag:
`scripts/drift_check.py` reads it, and `tests/drift-check.test.sh` asserts the golden
`tests/snapshots/local-stack/otel-local.compose.yaml` carries the same one.

## Step 1: Load context and select the service

Load `.claude/otel-context.json` exactly as `/otel-instrument` Step 1 does (freshness rule from
`/otel-init` Step 1; a stale or absent cache is refreshed as a merge, never a replace), and select
the target service exactly as `/otel-instrument` Step 2 does.

The service must already be instrumented, or there is nothing to see. Look for its bootstrap the
way `/otel-instrument` Step 4 does (`service.existingOtel.bootstrapFiles`, else the
`otel_bootstrap_globs` names under its `rootDir`). If there is none, say so and offer to run
`/otel-instrument` for it first; continue only once it has written one. Never generate a
bootstrap here.

## Step 2: Is Docker available?

Run `docker info --format '{{.ServerVersion}}'` and `docker compose version`. If either fails,
print one line and fall back to the console exporter, then stop:

```
Docker isn't available here (<"not installed" | "installed, but the daemon isn't running">), so there is no local stack; spans print to the console instead:
  OTEL_TRACES_EXPORTER=console <the service's run command>
```

Do not install Docker, do not suggest a different container runtime, and do not write either file.

## Step 3: Choose the host ports

The stack needs host ports 4317 (OTLP gRPC), 4318 (OTLP HTTP) and one for Grafana. Never ask the
user to move their app, and never pick a different port because one looked busy.

1. **Read the app's port from the repo first.** In order, take the first that applies to this
   service: a `PORT` default in its entry file (`process.env.PORT || 3000`, `os.getenv("PORT", "8000")`),
   a literal in its listen call (`listen(3000`, `app.run(port=5000`, `uvicorn ... --port`,
   `ListenAndServe(":8080"`, `Urls`/`launchSettings.json` `applicationUrl`, `server.port` in
   `application.properties`/`.yml`), the `start`/`dev` script, an `EXPOSE` in its Dockerfile,
   `ports:` in an existing compose file, then the framework default (Express none; Next.js,
   Rails, Grafana-style apps 3000; Flask 5000; Django 8000; Spring Boot and ASP.NET 8080 / 5000).
   Say which file and line it came from, or "not found in the repo".
2. **Grafana's host port:** `3000`, unless the app's port is 3000, then `3001`. If the app's port
   is 4317 or 4318, or is 3001 while 3000 is also unavailable, print which port collides and stop.
3. **Check every port is free:**
   `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/lgtm_check.py" ports --grafana-port <G>`.
   Exit 3 means at least one is taken. First check whether the listener is this stack itself
   (`docker compose -f otel-local.compose.yaml ps --status running -q` returns a container): then
   it is already up, so skip Step 6's start and go on. Otherwise print the script's `taken:` lines
   and stop:
   ```
   ⚠ Port <N> (<what>) is already in use, so the local stack can't start. Free it, or stop
     whatever is listening there (lsof -iTCP:<N> -sTCP:LISTEN shows it), then re-run /otel-local.
   ```
   Do not remap 4317/4318: every generated bootstrap and `otel-java.env` targets them.

Pyroscope (4040) and Tempo's own API (3200) are deliberately not published: everything is reached
through Grafana.

## Step 4: Generate the two files

Replace `<PLUGIN_VERSION>` with `.claude-plugin/plugin.json`'s `version`.

**`otel-local.compose.yaml`** (repo root). The Grafana port comment names the reason for the port
choice; drop the "because" clause when it is 3000.

```yaml
# Local observability stack: generated by otel-as-code v<PLUGIN_VERSION> (/otel-local). Re-run /otel-local to regenerate.
# For your machine only. grafana/otel-lgtm is one container with an OpenTelemetry Collector,
# Tempo (traces), Loki (logs), Prometheus (metrics), Pyroscope (profiles) and Grafana, with
# anonymous access and no persistence. Ports bind to 127.0.0.1 so nothing is reachable from
# your network, and no telemetry leaves this machine.
#   start: docker compose -f otel-local.compose.yaml up -d
#   stop:  docker compose -f otel-local.compose.yaml down
name: otel-local
services:
  lgtm:
    image: grafana/otel-lgtm:0.40.0
    ports:
      - "127.0.0.1:<G>:3000"   # Grafana UI; host <G> because the app listens on 3000
      - "127.0.0.1:4317:4317"   # OTLP gRPC
      - "127.0.0.1:4318:4318"   # OTLP HTTP
```

**`otel-local.env`** (the service's `rootDir`). Endpoint and protocol follow the transport the
service's bootstrap actually uses, never this plugin's usual default by assumption:

| Bootstrap | `OTEL_EXPORTER_OTLP_ENDPOINT` | `OTEL_EXPORTER_OTLP_PROTOCOL` |
|---|---|---|
| Node.js (`tracing.js`/`.ts`), Python, Go, .NET | `http://localhost:4317` | `grpc` |
| Ruby, Rust, PHP, Next.js on `@vercel/otel` | `http://localhost:4318` | `http/protobuf` |
| Java (`otel-java.env`) | omit both lines: `otel-java.env` already targets `localhost:4317` over gRPC | |

```dotenv
# Local telemetry wiring for <SERVICE_NAME>: generated by otel-as-code v<PLUGIN_VERSION> (/otel-local). Re-run /otel-local to regenerate.
# Points this service at the stack in otel-local.compose.yaml. Load it yourself, on your machine only:
#   <RUN_LINE>
# Nothing loads this file automatically (its name does not start with .env), so a deployed build
# never sees it and keeps exporting nowhere until its own endpoint is set.
OTEL_EXPORTER_OTLP_ENDPOINT=<per the table>
OTEL_EXPORTER_OTLP_PROTOCOL=<per the table>
OTEL_METRIC_EXPORT_INTERVAL=5000
DEPLOYMENT_ENV=local
```

`OTEL_METRIC_EXPORT_INTERVAL=5000` makes the first metric appear in seconds rather than a
minute. `DEPLOYMENT_ENV=local` feeds `deployment.environment.name` through the mechanism every
bootstrap already reads, so local data is never mistaken for a deployed environment's.

`<RUN_LINE>` is `set -a; . ./otel-local.env; set +a; <the service's run command>`. For Java, source
the agent config first so the local values win: `set -a; . ./otel-java.env; . ./otel-local.env; set +a; java -javaagent:...`.
On Windows outside Git Bash, also print the PowerShell form:
`Get-Content otel-local.env | Where-Object { $_ -match '^[A-Z]' } | ForEach-Object { $k, $v = $_ -split '=', 2; Set-Item "env:$k" $v }`.

## Step 5: Write the files

For each file:
- **Absent:** write it.
- **Present, identical:** leave it; say "unchanged".
- **Present with the `generated by otel-as-code` marker, different:** without `--force`, print a
  unified diff and "Re-run with `--force` to overwrite." and stop (the write-guard blocks the
  write anyway). With `--force`, authorize it exactly as `/otel-collector` Step 3 does (truncate
  `.claude/.otel-force` to the file's absolute path, write, then `rm -f .claude/.otel-force`).
- **Present without the marker:** a file of the user's own with this name. Stop and say so;
  `--force` does not override this.

`--dry-run`: print the port decision and each file (or its diff), write nothing, start nothing,
exit non-zero if anything would change.

Both files are safe to commit: they hold no secret and only ever point at localhost.

## Step 6: Start the stack and wait for Grafana

```
docker compose -f otel-local.compose.yaml up -d
```

The first run pulls the image (about 1 GB). Then poll `http://localhost:<G>/api/health` every
2 s for up to 120 s. If it never answers, print the last 30 lines of
`docker compose -f otel-local.compose.yaml logs lgtm` and stop; do not claim the stack is up.

## Step 7: Say where to look, then offer the check

Print, with the real port and service name:

```
✓ Local stack running on your machine (grafana/otel-lgtm:0.40.0). Nothing leaves this machine.

1. Start <SERVICE_NAME> against it:
     <RUN_LINE>
2. Use the app: hit any endpoint a few times.
3. Look:
   Traces   http://localhost:<G>  →  Explore  →  Tempo  →  Search, Service Name = <SERVICE_NAME>
   Logs     Explore  →  Loki, label service_name = <SERVICE_NAME>
   Metrics  Explore  →  Prometheus, metric browser; HTTP services report http_server_* metrics

A trace shows wall time: how long each step took, not whether it was busy on the CPU or waiting.
Pyroscope, in the same Grafana (Explore → Pyroscope), shows where CPU goes once a profiler sends to it; this plugin does not set one up.

Stop it any time: /otel-local --down
```

Qualify the Logs line from the service's bootstrap, never by assumption: when its logs signal is
off (Node.js logs are Development and need `/otel-instrument --experimental`; Python logs likewise;
.NET logs are a printed add-on), say "Logs: this bootstrap does not export logs yet (<why>)"
instead of pointing at Loki.

Then ask: "Once the app is running and you've hit it, want me to check that a trace arrived?" On
yes, run

```
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/lgtm_check.py" traces --grafana http://localhost:<G> --service <SERVICE_NAME> --since 900 --wait 30
```

and report its output as-is: it states what it asked (Tempo search through Grafana's datasource
proxy, with explicit start/end) and what came back. Exit 0: a trace arrived, name the root span.
Exit 1: none in the last 15 minutes; the usual causes are the app not started with the env file
loaded, or no request made yet. Exit 2: Grafana or Tempo unreachable. Never say traces arrived
unless this check ran and exited 0, and never run it on the user's behalf without the app having
been started.

## Step 8: `--down`

`docker compose -f otel-local.compose.yaml down` (only if the file exists; otherwise say there is
no local stack here). Then offer to delete `otel-local.compose.yaml` and every `otel-local.env`
under the repo. Delete only files carrying the marker, and say which were left because they lack
it. `/otel-uninstrument` never removes these files: it works per service, while the stack is
shared by the whole repo.
