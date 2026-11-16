"""Entry point for tests/e2e/log-trace-ids.sh: the python-greenfield app behind the golden
bootstrap, with the logging setup an application might have. LOG_MODE picks it. The bootstrap is
imported first, as /otel-instrument tells the user to, so every setup here runs AFTER it."""
import json
import logging
import os

import tracing

mode = os.environ["LOG_MODE"]
if mode == "plain":
    # The app's own format: it must survive, with the IDs added after it.
    logging.basicConfig(level=logging.INFO, format="APP %(levelname)s %(name)s | %(message)s")
elif mode == "json":
    from pythonjsonlogger import jsonlogger

    handler = logging.StreamHandler()
    handler.setFormatter(jsonlogger.JsonFormatter("%(levelname)s %(name)s %(message)s"))
    logging.basicConfig(level=logging.INFO, handlers=[handler])
elif mode == "custom":
    # A formatter class of the app's own that builds on the stock one, as structlog's does.
    class OneLineJson(logging.Formatter):
        def format(self, record):
            return json.dumps({"line": super().format(record)})

    handler = logging.StreamHandler()
    handler.setFormatter(OneLineJson("%(levelname)s %(message)s"))
    logging.basicConfig(level=logging.INFO, handlers=[handler])
elif mode == "handmade-json":
    # JSON written with the stock formatter and a format string.
    logging.basicConfig(level=logging.INFO, format='{"level": "%(levelname)s", "msg": "%(message)s"}')
elif mode == "own-ids":
    # A format that already shows the trace ID, as one written for
    # opentelemetry-instrumentation-logging would.
    logging.basicConfig(level=logging.INFO, format="%(levelname)s [%(otelTraceID)s] %(message)s")
else:
    raise SystemExit(f"unknown LOG_MODE {mode!r}")

from app import app  # noqa: E402

tracing.instrument_fastapi(app)
