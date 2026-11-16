#!/usr/bin/env python3
"""Renders what one alert says about itself (#288) as the lines a golden carries.

  alert_text_render.py <alert-text.json> <kind> <grafana|newrelic|datadog|dash0>

The text comes from skills/terraform-patterns/alert-text.json; each backend gets it in its own
field (Grafana rule annotations, New Relic `description`, Datadog `message`, Dash0 rule
annotations), with the links that backend can build from its own resources.
tests/alert-text.test.sh requires every alert in every golden to contain this output byte for
byte. Test-side only: the plugin's generator reads the table itself.
"""
import json, sys


def body(t):
    return f"Likely causes: {t['causes']} Check first: {t['check']}"


def render(table, kind, backend):
    t = table["kinds"][kind]
    if backend == "grafana":
        return [
            "    annotations = {",
            f'      summary     = "{t["meaning"]}"',
            f'      description = "{body(t)}"',
            "      dashboard   = grafana_dashboard.otel.url",
            "      traces      = local.traces_explore_url",
            "    }",
        ]
    if backend == "newrelic":
        return [f'  description = "{t["meaning"]} {body(t)} Dashboard: ${{newrelic_one_dashboard.otel.permalink}}"']
    if backend == "datadog":
        return [f'  message = "{t["meaning"]} {body(t)} Notify @your-team."']
    if backend == "dash0":
        return [
            "              annotations:",
            f'                summary: "{t["meaning"]}"',
            f'                description: "{body(t)}"',
        ]
    sys.exit(f"unknown backend {backend}")


if __name__ == "__main__":
    path, kind, backend = sys.argv[1:4]
    print("\n".join(render(json.load(open(path, encoding="utf-8")), kind, backend)))
