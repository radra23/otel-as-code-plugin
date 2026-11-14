# Recording the README demo

The demo in the top-level README (`docs/demo.gif`) is a **live recording** of Claude Code
running this plugin on the `checkout-api` fixture (`fixtures/nodejs-greenfield`). Nothing is
scripted or replayed. The only edit is to the clock: [`compress-cast.py`](compress-cast.py) plays
the stretches where the agent (or `npm install`) is working faster, so a few minutes of real
session fit in under a minute. Typing and output play at real speed, and every frame is kept.

Target: 40 to 60 seconds, ending on the `found: 3 trace(s)` line from the local stack check.

## One-time setup (macOS)

```bash
brew install asciinema agg gifsicle        # gifsicle is optional, it only shrinks the GIF
```

You also need Docker running (Docker Desktop, or any engine with `docker compose`), since
`/otel-local` starts the stack in it.

Use a plain prompt and no shell theme while recording, so the GIF shows nothing about your
machine: `export PS1='$ '` (zsh: `PROMPT='$ '`).

## Each take

```bash
bash docs/demo/setup.sh ~/otel-demo         # fresh, committed copy of the fixture
cd ~/otel-demo
claude --plugin-dir /path/to/otel-as-code-plugin   # once, off camera: accept the folder-trust
                                                   # prompt, then /exit
export OTEL_NODE_RESOURCE_DETECTORS=env     # off camera; see "Why the env var" below
asciinema rec --capture-input --cols 100 --rows 32 demo.cast   # asciinema 2.x: --stdin
```

`--capture-input` is required: the compressor uses your keystrokes to tell typing apart from
waiting, and refuses a recording without them.

## Shot list

The flow is the recommended first run: `/otel-init`, yes to "see this running locally", then the
first trace read back from the local Grafana stack. The fixture's app listens on 3000, so the
port line shows Grafana moving to 3001.

Off camera, before `asciinema rec`: start Docker and run `docker pull grafana/otel-lgtm:0.41.0`,
so the ~1 GB pull is not in the take.

| # | Type | What the viewer should see |
|---|---|---|
| 1 | `ls` | A plain Express app: `index.js`, `package.json`, `Dockerfile`. No OTel anywhere |
| 2 | `claude --plugin-dir /path/to/otel-as-code-plugin` | Claude Code starts |
| 3 | `/otel-init` | The scan, then the detected service (`checkout-api`, Node.js). Pause ~2s on the closing "Want to see this running locally now?" |
| 4 | `y` | `/otel-instrument` runs: `tracing.js` written, `package.json` updated. If it asks "Want me to add these to `Dockerfile`? [y/N]", answer `n`: that is the deployed endpoint, and the demo only needs the local one, which `/otel-local` writes to `otel-local.env`. Then `/otel-local`: the port line (app on 3000, so Grafana on 3001), the stack starting, and the "where to look" block with `http://localhost:3001`. Pause ~2s on that block |
| 5 | `/exit`, then `npm install` | Back to the shell (sped up) |
| 6 | The printed run line, with `&`: `set -a; . ./otel-local.env; set +a; npm start &` | The server starts |
| 7 | `for i in 1 2 3; do curl -s -XPOST localhost:3000/checkout -H 'content-type: application/json' -d '{"cartId":"c-42"}'; done` | Three JSON responses |
| 8 | `claude --plugin-dir /path/to/otel-as-code-plugin -c`, then "check that a trace arrived" | `checked: Tempo search via Grafana's datasource proxy ...` and `found: 3 trace(s); latest root span "POST /checkout"`. Hold ~3s, then stop recording (Ctrl-D) |

Pasting the long commands in 6 and 7 is fine; a paste is recorded as one keystroke event.

Then `kill %1` and `docker compose -f otel-local.compose.yaml down`.

**The Grafana view is a screenshot, not part of the GIF:** `asciinema` records the terminal only.
Open `http://localhost:3001`, Explore, Tempo, Search, Service Name = `checkout-api`, open one
trace, and capture the span waterfall as `docs/demo-grafana.png` (crop to the panel; the Grafana
sidebar shows nothing about your machine, but check the URL bar). Before the stack goes down, an
Explore, Prometheus graph of one `http_server_*` metric makes a good second image.

## Render

```bash
bash docs/demo/render.sh ~/otel-demo/demo.cast
```

This writes `docs/demo.gif` and prints its size. Aim for under 5 MB; GitHub shows larger
files, but they load slowly on the README. If the result is too long, tighten the waiting:

```bash
bash docs/demo/render.sh ~/otel-demo/demo.cast --speed 12 --max-wait 3
```

Watch the GIF all the way through before committing it. Check the first frame in particular:
Claude Code's welcome screen can show account or organisation details.

## Why the env var

By default the Node SDK's resource detectors add `host.name`, `host.id`, `process.owner`, and
the full command path to every span. Tempo's span detail in Grafana lists those resource
attributes, so without the env var the screenshot would show your machine's name, your OS
username, and your home directory. `OTEL_NODE_RESOURCE_DETECTORS=env` turns those detectors off.
The service identity (`service.name`, `service.version`, `service.namespace`,
`deployment.environment.name`) still appears, because the generated `tracing.js` sets it
directly.

It has to be exported in the shell that starts the app (step 6). Exporting it before
`asciinema rec` does that and keeps it out of the recording. It is a presentation choice, not a
change to what the plugin generates.
