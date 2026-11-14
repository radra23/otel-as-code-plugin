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
"""
import argparse
import json
import socket
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

OTLP_PORTS = (4317, 4318)


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
    args = p.parse_args(argv)
    return cmd_ports(args) if args.cmd == "ports" else cmd_traces(args)


if __name__ == "__main__":
    sys.exit(main())
