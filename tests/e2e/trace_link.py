#!/usr/bin/env python3
"""The trace-to-logs link of the local stack, for tests/e2e/log-panel.sh (#279).

grafana/otel-lgtm provisions its Tempo datasource with a tracesToLogsV2 query: the LogQL Grafana
runs when someone opens a trace and asks for its logs. This script starts from a trace, never
from a log line, and builds that query the way Grafana does, from the config the running Grafana
holds (not a copy of it), so a change to the image's link shows up here.

  trace_link.py trace-id --grafana URL --service NAME --traceql QUERY [--since S] [--wait S]
      The first trace in Tempo for QUERY whose root service is NAME, as 32 hex characters
      (Tempo's search drops leading zeros). Exit 0 found, 1 not found, 2 unreachable.

  trace_link.py query --service NAME --trace-id ID (--grafana URL | --datasource-json FILE)
      The LogQL the Tempo datasource's tracesToLogsV2 builds for that trace: ${__tags} becomes
      `label="value"` for each configured tag (only span attributes this script knows the value
      of, service.name today; any other tag fails rather than being dropped) and
      ${__trace.traceId} the trace ID. Prints the Loki datasource UID, then the query. Exit 0,
      1 when the datasource has no usable link. --datasource-json reads a saved
      /api/datasources/uid/tempo response (offline tests).
"""
import argparse
import json
import sys
import time
import urllib.error
import urllib.parse
import urllib.request


def fetch(url):
    with urllib.request.urlopen(url, timeout=5) as r:
        return json.load(r)


def cmd_trace_id(args):
    deadline = time.time() + args.wait
    while True:
        end = int(time.time())
        qs = urllib.parse.urlencode({"q": args.traceql, "start": end - args.since, "end": end, "limit": 20})
        try:
            body = fetch(f"{args.grafana.rstrip('/')}/api/datasources/proxy/uid/tempo/api/search?{qs}")
        except (urllib.error.URLError, OSError, ValueError) as e:
            print(f"unreachable: {e}", file=sys.stderr)
            return 2
        found = [t["traceID"] for t in body.get("traces") or [] if t.get("rootServiceName") == args.service]
        if found:
            print(found[0].rjust(32, "0"))
            return 0
        if time.time() >= deadline:
            print(f"no trace for {args.traceql}", file=sys.stderr)
            return 1
        time.sleep(2)


def render(datasource, service, trace_id):
    """(loki uid, query) from a Tempo datasource's tracesToLogsV2, or raise ValueError."""
    link = (datasource.get("jsonData") or {}).get("tracesToLogsV2") or {}
    if not link.get("customQuery") or not link.get("query") or not link.get("datasourceUid"):
        raise ValueError(f"no custom trace-to-logs query on this datasource: {link}")
    known = {"service.name": service}
    tags = []
    for tag in link.get("tags") or []:
        if tag["key"] not in known:
            raise ValueError(f"the link maps span attribute {tag['key']!r}, whose value this check does not know")
        tags.append(f'{tag.get("value") or tag["key"]}="{known[tag["key"]]}"')
    query = link["query"].replace("${__tags}", ", ".join(tags)).replace("${__trace.traceId}", trace_id)
    if "$" in query:
        raise ValueError(f"a variable is left in the query: {query}")
    return link["datasourceUid"], query


def cmd_query(args):
    if args.datasource_json:
        with open(args.datasource_json) as f:
            datasource = json.load(f)
    else:
        datasource = fetch(f"{args.grafana.rstrip('/')}/api/datasources/uid/tempo")
    try:
        uid, query = render(datasource, args.service, args.trace_id)
    except ValueError as e:
        print(e, file=sys.stderr)
        return 1
    print(uid)
    print(query)
    return 0


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    t = sub.add_parser("trace-id")
    t.add_argument("--grafana", required=True)
    t.add_argument("--service", required=True)
    t.add_argument("--traceql", required=True)
    t.add_argument("--since", type=int, default=900)
    t.add_argument("--wait", type=int, default=0)
    q = sub.add_parser("query")
    q.add_argument("--service", required=True)
    q.add_argument("--trace-id", required=True)
    src = q.add_mutually_exclusive_group(required=True)
    src.add_argument("--grafana")
    src.add_argument("--datasource-json")
    args = p.parse_args(argv)
    return cmd_trace_id(args) if args.cmd == "trace-id" else cmd_query(args)


if __name__ == "__main__":
    sys.exit(main())
