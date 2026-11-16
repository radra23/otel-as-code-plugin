#!/usr/bin/env python3
"""Renders one language's runtime panel row as the HCL the Grafana goldens carry (#277).

  runtime_panels_render.py <runtime-panels.json> <language> <y>

The row header sits at grid row <y>, its panels at <y>+1. tests/runtime-panels.test.sh requires
each Grafana golden to contain this output byte for byte, so the goldens cannot drift from the
table; the same file regenerates the block when the table changes. Test-side only: the plugin's
generator reads the table itself.
"""
import json, sys

NOT_STABLE = (" Its name is not yet stable in the OpenTelemetry semantic conventions: if the panel"
              " goes blank after an SDK upgrade, check whether the metric was renamed.")


def description(panel):
    text = f"{panel['metric']}, emitted by the generated bootstrap with no application code."
    return text + ("" if panel["stability"] == "stable" else NOT_STABLE)


def hcl(text):
    return text.replace("\\", "\\\\").replace('"', '\\"')


def render(table, language, y):
    lang = table["languages"][language]
    panels = lang["panels"]
    width = 24 // len(panels)
    out = [
        "      # Runtime row: chosen by the service's language from terraform-patterns'",
        "      # runtime-panels.json. Every query in that table is run against Prometheus in the",
        "      # trace-flow e2e job.",
        "      {",
        f'        title     = "Runtime ({lang["label"]})"',
        '        type      = "row"',
        "        collapsed = false",
        f"        gridPos   = {{ h = 1, w = 24, x = 0, y = {y} }}",
        "      },",
    ]
    for i, panel in enumerate(panels):
        out += [
            "      {",
            f'        title       = "{hcl(panel["title"])}"',
            f'        description = "{hcl(description(panel))}"',
            '        type        = "timeseries"',
            f"        gridPos     = {{ h = 8, w = {width}, x = {i * width}, y = {y + 1} }}",
            f'        fieldConfig = {{ defaults = {{ unit = "{panel["grafanaUnit"]}" }} }}',
            "        targets = [{",
            '          refId = "A"',
            f'          expr  = "{hcl(panel["grafana"])}"',
            "        }]",
            "      },",
        ]
    return "\n".join(out) + "\n"


if __name__ == "__main__":
    path, language, y = sys.argv[1:4]
    sys.stdout.write(render(json.load(open(path, encoding="utf-8")), language, int(y)))
