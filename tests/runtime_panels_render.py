#!/usr/bin/env python3
"""Renders one language's runtime panel row as the HCL the Grafana goldens carry (#277).

  runtime_panels_render.py <runtime-panels.json> <language> <y> [grafana|newrelic|dash0]

For Grafana the row header sits at grid row <y>, its panels at <y>+1 (the other two ignore <y>:
New Relic gets a page of its own, Dash0 dashboards have no grid). tests/runtime-panels.test.sh
requires each golden to contain this output byte for byte, so the goldens cannot drift from the
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


NOT_RUN = "This query was derived from the metric the bootstrap emits and was not run against live data."


def nrql(panel):
    """New Relic queries a metric by its OpenTelemetry name; the aggregation follows its kind."""
    name = f"`{panel['metric']}`"
    select = {"counter": f"rate(sum({name}), 1 second)", "histogram": f"rate(count({name}), 1 second)"}.get(
        panel["kind"], f"average({name})")
    facet = f" FACET `{panel['facet']}`" if panel.get("facet") else ""
    return f"SELECT {select} FROM Metric WHERE service.name = '${{var.service_name}}'{facet} TIMESERIES"


def render_newrelic(table, language):
    lang = table["languages"][language]
    panels = lang["panels"]
    width = 12 // len(panels)
    out = [
        "  # Runtime page: chosen by the service's language from terraform-patterns'",
        "  # runtime-panels.json. New Relic stores a metric under its OpenTelemetry name, so each query",
        "  # follows from the table's metric and kind. None of them has been run against live data.",
        "  page {",
        f'    name = "Runtime ({lang["label"]})"',
        "",
    ]
    for i, panel in enumerate(panels):
        out += [
            "    widget_line {",
            f'      title  = "{hcl(panel["title"])}"',
            "      row    = 1",
            f"      column = {i * width + 1}",
            f"      width  = {width}",
            "      height = 3",
            "      nrql_query {",
            "        account_id = var.newrelic_account_id",
            f'        query      = "{nrql(panel)}"',
            "      }",
            "    }",
            "",
        ]
    names = ", ".join(sorted({p["metric"] for p in panels if p["stability"] != "stable"}))
    note = ("Runtime metrics the generated bootstrap emits with no application code. These queries were derived from the "
            "metric names and were not run against a New Relic account: if a chart is empty, look the metric up in the "
            "Metrics explorer.")
    if names:
        note += f" Names not yet stable in the OpenTelemetry semantic conventions, which a later SDK release may rename: {names}."
    out += [
        "    widget_markdown {",
        '      title  = "About this page"',
        "      row    = 4",
        "      column = 1",
        "      width  = 12",
        "      height = 2",
        f'      text   = "{hcl(note)}"',
        "    }",
        "  }",
    ]
    return "\n".join(out) + "\n"


def key(title):
    words = "".join(c if c.isalnum() else " " for c in title).split()
    return "runtime" + "".join(w[:1].upper() + w[1:] for w in words)


def render_dash0(table, language):
    lang = table["languages"][language]
    out = []
    for panel in lang["panels"]:
        query = panel["grafana"].replace('job="${var.service_name}"', 'service_name="${var.service_name}"')
        text = f"{panel['metric']}. {NOT_RUN}" + ("" if panel["stability"] == "stable" else NOT_STABLE)
        out += [
            f"        {key(panel['title'])}:",
            "          kind: Panel",
            "          spec:",
            "            display:",
            f"              name: {lang['label']} runtime, {panel['title'][:1].lower() + panel['title'][1:]}",
            f"              description: {json.dumps(text)}",
            "            plugin:",
            "              kind: TimeSeriesChart",
            "            queries:",
            "              - kind: TimeSeriesQuery",
            "                spec:",
            "                  plugin:",
            "                    kind: PrometheusTimeSeriesQuery",
            "                    spec:",
            f"                      query: {query}",
        ]
    return "\n".join(out) + "\n"


if __name__ == "__main__":
    path, language, y = sys.argv[1:4]
    backend = sys.argv[4] if len(sys.argv) > 4 else "grafana"
    table = json.load(open(path, encoding="utf-8"))
    sys.stdout.write({"grafana": lambda: render(table, language, int(y)),
                      "newrelic": lambda: render_newrelic(table, language),
                      "dash0": lambda: render_dash0(table, language)}[backend]())
