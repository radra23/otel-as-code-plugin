#!/usr/bin/env python3
"""Checks for the local grafana/otel-lgtm stack that /otel-local starts.

One script, two callers: /otel-local runs it on the user's machine and the local-stack e2e job
runs it in CI (through tests/e2e/assert-lgtm.sh), so the check the plugin claims is the check CI
proves. Standard library only; JSON over plain http to localhost.

  lgtm_check.py ports --grafana-port N
      Is each host port the stack needs (4317, 4318, N) free? Prints one line per port.
      Exit 0 all free, 3 any taken (the caller says which and stops; it never picks another).

  lgtm_check.py traces --grafana URL --service NAME [--since SECONDS] [--wait SECONDS]
                       [--search-json FILE]
      Did a trace for NAME reach Tempo? Asks Tempo through Grafana's datasource proxy
      (/api/datasources/proxy/uid/tempo/api/search) because the image does not publish Tempo's
      own :3200, and always passes explicit start/end: without them Tempo's search can come back
      empty for traces that are there. Prints exactly what it asked and what came back.
      Exit 0 found, 1 nothing found, 2 Grafana or Tempo unreachable.
      --search-json reads a saved search response instead of calling Grafana (offline tests).

  lgtm_check.py span --grafana URL --service NAME --name SPAN [--parent PARENT] [--status error]
                     [--since SECONDS] [--wait SECONDS] [--trace-json FILE]
      Did a span called SPAN reach Tempo for NAME, and what is it nested under? Same route as
      `traces` (datasource proxy, explicit start/end): a TraceQL search for the span, then the
      trace itself. Prints the span's duration, status and its parent's name. With --parent, the
      parent must have that name; with --status error, only a span that recorded an error counts.
      Exit 0 found (and the parent matches), 1 not found or a different parent, 2 unreachable.
      --trace-json reads a saved trace instead of calling Grafana.

  lgtm_check.py query --grafana URL --expr PROMQL [--positive] [--max N] [--wait SECONDS]
                      [--names REGEX] [--result-json FILE]
      Does a dashboard panel's query return data? Runs PROMQL as an instant query against the
      stack's Prometheus, through Grafana's datasource proxy. Prints how many series came back
      and the first value. Exit 0 when a series has a real number (with --positive, above zero;
      with --max, no value above N), 1 when nothing or only NaN came back, 2 unreachable. On exit 1, --names REGEX also prints
      the metric names Prometheus does have that match it, which is usually the answer (a metric
      is stored under its name with dots as underscores, its unit and, for a counter, _total).
      --result-json reads a saved query response instead of calling Grafana.
"""
import argparse
import base64
import json
import math
import re
import socket
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

def port_in_use(port, host="127.0.0.1"):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(0.5)
    try:
        return s.connect_ex((host, port)) == 0
    finally:
        s.close()


def cmd_ports(args):
    taken = []
    for port, what in ((4317, "OTLP gRPC"), (4318, "OTLP HTTP"), (args.grafana_port, "Grafana")):
        if port_in_use(port):
            taken.append(port)
            print(f"taken: {port} ({what}) already has a listener")
        else:
            print(f"free:  {port} ({what})")
    return 3 if taken else 0


def search_url(grafana, service, start, end):
    q = '{resource.service.name="%s"}' % service
    qs = urllib.parse.urlencode({"q": q, "start": start, "end": end, "limit": 20})
    return f"{grafana.rstrip('/')}/api/datasources/proxy/uid/tempo/api/search?{qs}"


def matching_traces(body, service):
    """Traces in a Tempo search response whose root service is `service`."""
    return [t for t in body.get("traces") or [] if t.get("rootServiceName") == service]


def fetch(url):
    with urllib.request.urlopen(url, timeout=5) as r:
        return json.load(r)


def cmd_traces(args):
    if args.search_json:
        with open(args.search_json) as f:
            body = json.load(f)
        found = matching_traces(body, args.service)
        print(f"checked: saved Tempo search response {args.search_json} for service.name={args.service}")
        print(f"found: {len(found)} trace(s)" if found else "found: no traces for that service")
        return 0 if found else 1

    deadline = time.time() + args.wait
    while True:
        end = int(time.time())
        url = search_url(args.grafana, args.service, end - args.since, end)
        try:
            found = matching_traces(fetch(url), args.service)
            reached = True
        except (urllib.error.URLError, OSError, ValueError) as e:
            found, reached, err = [], False, e
        if found or time.time() >= deadline:
            break
        time.sleep(2)

    print(f"checked: Tempo search via Grafana's datasource proxy, service.name={args.service}, "
          f"last {args.since}s (start/end set explicitly)")
    print(f"  {url}")
    if not reached:
        print(f"unreachable: {err}")
        return 2
    if found:
        t = found[0]
        print(f"found: {len(found)} trace(s); latest root span \"{t.get('rootTraceName')}\" "
              f"took {t.get('durationMs')} ms")
        return 0
    print("found: no traces for that service in that window")
    return 1


def span_search_url(grafana, service, name, start, end, status=None):
    q = '{resource.service.name="%s" && name="%s"%s}' % (service, name, " && status=error" if status == "error" else "")
    qs = urllib.parse.urlencode({"q": q, "start": start, "end": end, "limit": 5})
    return f"{grafana.rstrip('/')}/api/datasources/proxy/uid/tempo/api/search?{qs}"


def span_id(raw):
    """Tempo returns span ids base64-encoded; OTLP/JSON elsewhere uses hex. Compare as hex."""
    if not raw:
        return ""
    if len(raw) == 16 and all(c in "0123456789abcdefABCDEF" for c in raw):
        return raw.lower()
    try:
        return base64.b64decode(raw).hex()
    except ValueError:
        return raw


def spans_in(trace):
    """Every span of one Tempo trace document as {id, parent, name, ms}."""
    if isinstance(trace.get("trace"), dict):
        trace = trace["trace"]
    out = []
    for rs in trace.get("batches") or trace.get("resourceSpans") or []:
        for ss in rs.get("scopeSpans") or []:
            for sp in ss.get("spans") or []:
                ms = (int(sp.get("endTimeUnixNano", 0)) - int(sp.get("startTimeUnixNano", 0))) / 1e6
                code = str((sp.get("status") or {}).get("code", ""))
                out.append({"id": span_id(sp.get("spanId")), "parent": span_id(sp.get("parentSpanId")),
                            "name": sp.get("name", "?"), "ms": ms,
                            "error": code in ("STATUS_CODE_ERROR", "2")})
    return out


def find_span(trace, name, status=None):
    """(span, parent name or None) for the first span called `name`, or (None, None)."""
    spans = spans_in(trace)
    by_id = {sp["id"]: sp for sp in spans}
    for sp in spans:
        if sp["name"] == name and (status != "error" or sp["error"]):
            parent = by_id.get(sp["parent"])
            return sp, parent["name"] if parent else None
    return None, None


def cmd_span(args):
    if args.trace_json:
        with open(args.trace_json) as f:
            traces = [json.load(f)]
        print(f"checked: saved trace {args.trace_json} for a span named {args.name}")
    else:
        deadline = time.time() + args.wait
        while True:
            end = int(time.time())
            url = span_search_url(args.grafana, args.service, args.name, end - args.since, end, args.status)
            try:
                base = args.grafana.rstrip("/") + "/api/datasources/proxy/uid/tempo/api/traces/"
                traces = [fetch(base + t["traceID"]) for t in (fetch(url).get("traces") or [])[:1]]
                reached = True
            except (urllib.error.URLError, OSError, ValueError) as e:
                traces, reached, err = [], False, e
            if traces or time.time() >= deadline:
                break
            time.sleep(2)
        print(f"checked: Tempo search via Grafana's datasource proxy, service.name={args.service}, "
              f"span name={args.name}, last {args.since}s (start/end set explicitly)")
        print(f"  {url}")
        if not reached:
            print(f"unreachable: {err}")
            return 2
    for trace in traces:
        sp, parent = find_span(trace, args.name, args.status)
        if sp:
            under = f'nested under "{parent}"' if parent else "with no parent in this trace (a root span)"
            state = "recorded an error" if sp["error"] else "no error"
            print(f'found: span "{args.name}" took {sp["ms"]:.1f} ms, {state}, {under}')
            if args.parent and parent != args.parent:
                print(f'mismatch: expected it nested under "{args.parent}"')
                return 1
            return 0
    what = "no span" if args.status != "error" else "no span with an error"
    print(f"found: {what} named {args.name}" + ("" if args.trace_json else " for that service in that window"))
    return 1


def prom_url(grafana, path, params):
    return f"{grafana.rstrip('/')}/api/datasources/proxy/uid/prometheus/api/v1/{path}?{urllib.parse.urlencode(params)}"


def numbers_in(body):
    """(series count, the finite sample values) of an instant-query response."""
    data = body.get("data") or {}
    result = data.get("result") or []
    if data.get("resultType") == "scalar":
        result = [{"value": result}]
    out = []
    for series in result:
        try:
            v = float((series.get("value") or [None, "nan"])[1])
        except (TypeError, ValueError):
            continue
        if math.isfinite(v):
            out.append(v)
    return len(result), out


def cmd_query(args):
    if args.result_json:
        with open(args.result_json) as f:
            body = json.load(f)
        print(f"checked: saved query response {args.result_json}")
    else:
        deadline = time.time() + args.wait
        while True:
            url = prom_url(args.grafana, "query", {"query": args.expr})
            try:
                body = fetch(url)
                reached = True
            except (urllib.error.URLError, OSError, ValueError) as e:
                body, reached, err = {}, False, e
            series, values = numbers_in(body)
            if (values and (not args.positive or max(values) > 0)) or time.time() >= deadline:
                break
            time.sleep(3)
        print("checked: Prometheus instant query via Grafana's datasource proxy")
        print(f"  {args.expr}")
        if not reached:
            print(f"unreachable: {err}")
            return 2
    series, values = numbers_in(body)
    if values and args.max is not None and max(values) > args.max:
        print(f"found: {series} series; first value {values[0]:g}, above the expected maximum {args.max:g}")
        return 1
    if values and (not args.positive or max(values) > 0):
        print(f"found: {series} series; first value {values[0]:g}")
        return 0
    if series and not values:
        print(f"found: {series} series, but no number yet (NaN: the metric exists and has not changed in the window)")
    elif values:
        print(f"found: {series} series, all zero")
    else:
        print("found: no data for that query")
    if args.names and not args.result_json:
        try:
            names = fetch(prom_url(args.grafana, "label/__name__/values", {})).get("data") or []
            hits = [n for n in names if re.search(args.names, n)]
            print(f"metric names matching /{args.names}/: {', '.join(hits) if hits else 'none'}")
        except (urllib.error.URLError, OSError, ValueError) as e:
            print(f"could not list metric names: {e}")
    return 1


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    pp = sub.add_parser("ports")
    pp.add_argument("--grafana-port", type=int, required=True)
    pt = sub.add_parser("traces")
    pt.add_argument("--grafana", default="http://localhost:3000")
    pt.add_argument("--service", required=True)
    pt.add_argument("--since", type=int, default=900)
    pt.add_argument("--wait", type=int, default=0)
    pt.add_argument("--search-json")
    ps = sub.add_parser("span")
    ps.add_argument("--grafana", default="http://localhost:3000")
    ps.add_argument("--service")
    ps.add_argument("--name", required=True)
    ps.add_argument("--parent")
    ps.add_argument("--status", choices=["error"])
    ps.add_argument("--since", type=int, default=900)
    ps.add_argument("--wait", type=int, default=0)
    ps.add_argument("--trace-json")
    pq = sub.add_parser("query")
    pq.add_argument("--grafana", default="http://localhost:3000")
    pq.add_argument("--expr")
    pq.add_argument("--positive", action="store_true")
    pq.add_argument("--max", type=float)
    pq.add_argument("--wait", type=int, default=0)
    pq.add_argument("--names")
    pq.add_argument("--result-json")
    args = p.parse_args(argv)
    if args.cmd == "span" and not args.trace_json and not args.service:
        p.error("span needs --service (or --trace-json)")
    if args.cmd == "query" and not args.result_json and not args.expr:
        p.error("query needs --expr (or --result-json)")
    return {"ports": cmd_ports, "traces": cmd_traces, "span": cmd_span, "query": cmd_query}[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main())
