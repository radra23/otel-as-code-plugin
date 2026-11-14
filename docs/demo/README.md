# Recording the README demo

The demo in the top-level README (`docs/demo.gif`) is a **live recording** of Claude Code
running this plugin on the `checkout-api` fixture (`fixtures/nodejs-greenfield`). Nothing is
scripted or replayed. The only edit is to the clock: [`compress-cast.py`](compress-cast.py) plays
the stretches where the agent (or `npm install`) is working faster, so a few minutes of real
session fit in under a minute. Typing and output play at real speed, and every frame is kept.

Target: 40 to 60 seconds, ending on a span with `service.name: checkout-api` on screen.

## One-time setup (macOS)

```bash
brew install asciinema agg gifsicle        # gifsicle is optional, it only shrinks the GIF
```

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

| # | Type | What the viewer should see |
|---|---|---|
| 1 | `ls` | A plain Express app: `index.js`, `package.json`, `Dockerfile`. No OTel anywhere |
| 2 | `claude --plugin-dir /path/to/otel-as-code-plugin` | Claude Code starts |
| 3 | `/otel-init` | The scan, then the detected service (`checkout-api`, Node.js). Pause ~2s on the summary |
| 4 | `/otel-instrument` | `tracing.js` written, `package.json` updated (OTel dependencies, and `-r ./tracing.js` on the start script), and the note that no OTLP endpoint is configured. Answer `n` to the offer to write the endpoint settings. Pause ~2s |
| 5 | `/exit` | Back to the shell |
| 6 | `npm install` | (sped up) |
| 7 | `npm start`, wait a second, Ctrl-C | The `[otel] No OTEL_EXPORTER_OTLP_ENDPOINT is configured ... emits no telemetry` warning. This is the safe default: no endpoint means no exporter, instead of a silent reconnect loop to `localhost:4317` |
| 8 | `OTEL_TRACES_EXPORTER=console npm start &` | The server starts |
| 9 | `curl -s -XPOST localhost:3000/checkout -H 'content-type: application/json' -d '{"cartId":"c-42"}'` | Spans print: `POST /checkout` with `http.route`, `http.response.status_code`, and the `checkout-api` resource. Stop recording (Ctrl-D) once they finish |

Pasting the long commands in 8 and 9 is fine; a paste is recorded as one keystroke event.

Then `kill %1` to stop the background server.

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
the full command path to every span, which would put your machine's name, your OS username, and
your home directory into a public GIF. `OTEL_NODE_RESOURCE_DETECTORS=env` turns those detectors
off. The service identity (`service.name`, `service.version`, `service.namespace`,
`deployment.environment.name`) still appears, because the generated `tracing.js` sets it
directly. It also cuts the output for one request from about 270 lines to about 170, so a
whole span fits on screen in the final frame.

Exporting it before `asciinema rec` keeps it out of the recording. That is a presentation
choice, not a change to what the plugin generates.
