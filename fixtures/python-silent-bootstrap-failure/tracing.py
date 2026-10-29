"""Hand-written OTel bootstrap. Regression fixture for #194: setup() is wrapped in its own
try/except, and the import inside it is wrong for the SDK version these >= floors resolve to
(opentelemetry.sdk.logs was renamed opentelemetry.sdk._logs) -- a ModuleNotFoundError is raised
before any provider is registered, and the except swallows it. The app keeps running on the
OTel API's no-op defaults; nothing in this file's text looks wrong, which is exactly why a
static-reading audit cannot catch it -- only bootstrapHealth (an actual import) can.
"""
import logging

logger = logging.getLogger(__name__)


def setup():
    try:
        from opentelemetry import trace
        from opentelemetry.sdk.trace import TracerProvider
        from opentelemetry.sdk.logs import LoggerProvider  # wrong: opentelemetry.sdk._logs

        trace.set_tracer_provider(TracerProvider())
    except Exception:
        logger.warning("OTel setup failed; continuing without telemetry", exc_info=True)


def shutdown():
    pass
