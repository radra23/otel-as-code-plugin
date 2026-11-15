#!/usr/bin/env python3
"""Turn traces from the local stack into an evidence table for /otel-why.

The agent's diagnosis must quote this table, so the numbers come from code, not from a model
reading raw JSON. Standard library only; it talks to localhost and nothing else.

  trace_summary.py --grafana URL --service NAME [--route "POST /checkout"] [--since SECONDS]
                   [--limit N] [--save-dir DIR] [--min-ms MS] [--json]
      Find the service's recent traces in Tempo through Grafana's datasource proxy (Tempo's own
      port is not published by the local stack), always with explicit start/end, fetch each one,
      and summarize them. --route keeps only traces whose root span has that name. --save-dir
      also writes every fetched trace to DIR, as Tempo returned it.

  trace_summary.py --trace-json FILE [FILE ...] [--route ...] [--min-ms MS] [--json]
      Summarize saved traces instead (the offline tests; a re-read of saved evidence).

  --slowest K (either form) summarizes only the K slowest requests: for a symptom that happens
  "sometimes", the median over every request hides it. The header says the set was narrowed.

How the table is built, per trace and then as the median across traces:
  - a span's self time is its duration minus the part of it its children cover;
  - spans are grouped by name (an outbound call also by where it went) and summed per request;
  - rows are ranked by self time per request; share is that over the whole request's duration;
  - three or more same-name siblings under one parent get a shape: "one after another" when
    each starts after the previous one ends, "at the same time" when they overlap, else "mixed";
  - a probe span's CPU column comes from the otel_as_code.probe.cpu_ms attribute the probe
    helper records.
The top row "stands out" when its share is at least 40% and its self time at least --min-ms
(default 50). Otherwise the summary says nothing stands out, and names no cause.

Exit 0 with a summary, 1 when no matching trace was found, 2 when Grafana or Tempo is unreachable.
"""
import argparse
import base64
import json
import os
import statistics
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

PROBE_SCOPE = "otel-as-code.probe"
CPU_ATTR = "otel_as_code.probe.cpu_ms"
STANDS_OUT_SHARE = 0.40
SEQ_TOLERANCE_NS = 1_000_000  # 1 ms: a sibling may start this much before the previous one ends
KIND_NAMES = {0: "unspecified", 1: "internal", 2: "server", 3: "client", 4: "producer", 5: "consumer"}


# --- reading Tempo's JSON -----------------------------------------------------------------------

def attr_value(v):
    for key in ("stringValue", "intValue", "doubleValue", "boolValue"):
        if key in v:
            return v[key]
    return None


def attrs(items):
    return {a.get("key"): attr_value(a.get("value") or {}) for a in items or []}


def kind_name(k):
    if isinstance(k, str):
        return k.replace("SPAN_KIND_", "").lower()
    return KIND_NAMES.get(k, "unspecified")


def norm_id(i):
    """Tempo returns base64 ids; OTLP/JSON from elsewhere uses hex. Compare them as hex."""
    if not i:
        return ""
    try:
        if len(i) in (16, 32) and all(c in "0123456789abcdefABCDEF" for c in i):
            return i.lower()
        return base64.b64decode(i).hex()
    except ValueError:
        return i


def spans_of(doc):
    """Every span in one trace document, whatever envelope Tempo used."""
    if "trace" in doc and isinstance(doc["trace"], dict):
        doc = doc["trace"]
    out = []
    for rs in doc.get("batches") or doc.get("resourceSpans") or []:
        resource = attrs((rs.get("resource") or {}).get("attributes"))
        for ss in rs.get("scopeSpans") or rs.get("instrumentationLibrarySpans") or []:
            scope = (ss.get("scope") or ss.get("instrumentationLibrary") or {}).get("name", "")
            for s in ss.get("spans") or []:
                a = attrs(s.get("attributes"))
                out.append({
                    "id": norm_id(s.get("spanId")),
                    "parent": norm_id(s.get("parentSpanId")),
                    "name": s.get("name", "?"),
                    "kind": kind_name(s.get("kind", 0)),
                    "start": int(s.get("startTimeUnixNano", 0)),
                    "end": int(s.get("endTimeUnixNano", 0)),
                    "scope": scope,
                    "attrs": a,
                    "service": resource.get("service.name"),
                })
    return out


def source_of(span):
    if span["scope"] == PROBE_SCOPE:
        return "probe"
    if span["scope"].startswith("@opentelemetry/instrumentation") or span["scope"].startswith("opentelemetry.instrumentation"):
        return "auto"
    return "app"


def label_of(span):
    """Group key. An outbound call is grouped by where it went, so two services stay apart."""
    if span["kind"] != "client":
        return span["name"]
    a = span["attrs"]
    target = a.get("url.full") or a.get("http.url")
    if target:
        target = target.split("?")[0]
    else:
        host = a.get("server.address") or a.get("net.peer.name")
        port = a.get("server.port") or a.get("net.peer.port")
        target = f"{host}:{port}" if host and port else host
    return f"{span['name']} {target}" if target else span["name"]


# --- per-trace measurements ---------------------------------------------------------------------

def covered(intervals, lo, hi):
    """Total length of the union of intervals, clipped to [lo, hi]."""
    total, cur_s, cur_e = 0, None, None
    for s, e in sorted((max(s, lo), min(e, hi)) for s, e in intervals):
        if e <= s:
            continue
        if cur_e is None or s > cur_e:
            if cur_e is not None:
                total += cur_e - cur_s
            cur_s, cur_e = s, e
        else:
            cur_e = max(cur_e, e)
    if cur_e is not None:
        total += cur_e - cur_s
    return total


def shape_of(group):
    """Shape of 3+ same-name siblings: one after another, at the same time, or mixed."""
    g = sorted(group, key=lambda s: s["start"])
    if all(b["start"] >= a["end"] - SEQ_TOLERANCE_NS for a, b in zip(g, g[1:])):
        return "one after another"
    durations = sum(s["end"] - s["start"] for s in g)
    union = covered([(s["start"], s["end"]) for s in g], g[0]["start"], max(s["end"] for s in g))
    return "at the same time" if durations and union / durations <= 0.5 else "mixed"


def summarize_trace(spans):
    by_id = {s["id"]: s for s in spans}
    children = {}
    for s in spans:
        if s["parent"] in by_id:
            children.setdefault(s["parent"], []).append(s)
    roots = [s for s in spans if s["parent"] not in by_id]
    root = max(roots, key=lambda s: s["end"] - s["start"])
    rows = {}
    for s in spans:
        kids = children.get(s["id"], [])
        dur = s["end"] - s["start"]
        self_ns = dur - covered([(k["start"], k["end"]) for k in kids], s["start"], s["end"])
        r = rows.setdefault(label_of(s), {"label": label_of(s), "name": s["name"], "kind": s["kind"],
                                          "source": source_of(s), "count": 0, "total": 0, "self": 0,
                                          "cpu": None, "leaf": True, "shapes": [], "parents": set()})
        r["count"] += 1
        r["total"] += dur
        r["self"] += self_ns
        r["leaf"] = r["leaf"] and not kids
        cpu = s["attrs"].get(CPU_ATTR)
        if cpu is not None:
            r["cpu"] = (r["cpu"] or 0) + float(cpu)
        if s["parent"] in by_id:
            r["parents"].add(by_id[s["parent"]]["name"])
    for parent_id, kids in children.items():
        groups = {}
        for k in kids:
            groups.setdefault(label_of(k), []).append(k)
        for label, g in groups.items():
            if len(g) >= 3:
                d = sorted(k["end"] - k["start"] for k in g)
                rows[label]["shapes"].append({"shape": shape_of(g), "n": len(g),
                                              "each_ns": d[len(d) // 2], "under": by_id[parent_id]["name"]})
    return {"root": root["name"], "root_ns": root["end"] - root["start"],
            "window": (root["start"], root["end"]), "rows": rows}


# --- across traces ------------------------------------------------------------------------------

def median(xs):
    return statistics.median(xs) if xs else 0


def ms(ns):
    return ns / 1e6


def summarize(traces, min_ms=50.0, slowest=None):
    per = [summarize_trace(t) for t in traces if t]
    seen = len(per)
    if slowest:
        per = sorted(per, key=lambda p: -p["root_ns"])[:slowest]
    root_ns = [p["root_ns"] for p in per]
    windows = sorted(p["window"] for p in per)
    overlapped = any(b[0] < a[1] for a, b in zip(windows, windows[1:]))
    labels = {}
    for p in per:
        for label, r in p["rows"].items():
            labels.setdefault(label, []).append(r)
    rows = []
    for label, rs in labels.items():
        first = rs[0]
        cpus = [r["cpu"] for r in rs if r["cpu"] is not None]
        shapes = [s for r in rs for s in r["shapes"]]
        shape = None
        if shapes:
            common = max({s["shape"] for s in shapes}, key=lambda k: sum(s["shape"] == k for s in shapes))
            pick = [s for s in shapes if s["shape"] == common]
            shape = {"shape": common, "n": int(median([s["n"] for s in pick])),
                     "each_ms": round(ms(median([s["each_ns"] for s in pick])), 1), "under": pick[0]["under"]}
        self_ms = ms(median([r["self"] for r in rs]))
        rows.append({
            "span": label, "name": first["name"], "kind": first["kind"], "source": first["source"],
            "in_traces": len(rs), "per_request": int(median([r["count"] for r in rs])),
            "total_ms": round(ms(median([r["total"] for r in rs])), 1), "self_ms": round(self_ms, 1),
            "cpu_ms": round(median(cpus), 1) if cpus else None,
            "share": round(self_ms / ms(median(root_ns)), 3) if root_ns and median(root_ns) else 0,
            "leaf": all(r["leaf"] for r in rs), "shape": shape,
        })
    rows.sort(key=lambda r: (-r["self_ms"], r["span"]))
    top = rows[0] if rows else None
    stands_out = bool(top and top["share"] >= STANDS_OUT_SHARE and top["self_ms"] >= min_ms)
    root_name = max({p["root"] for p in per}, key=lambda n: sum(p["root"] == n for p in per)) if per else None
    return {
        "traces": len(per), "traces_seen": seen, "slowest": slowest if slowest else None, "root": root_name,
        "request_ms": {"median": round(ms(median(root_ns)), 1),
                       "p95": round(ms(sorted(root_ns)[min(len(root_ns) - 1, int(len(root_ns) * 0.95))]), 1) if root_ns else 0},
        "requests_overlapped": overlapped, "min_ms": min_ms,
        "stands_out": stands_out, "top": top["span"] if stands_out else None, "rows": rows,
    }


# --- what the summary says, in plain words --------------------------------------------------------

def pct(share):
    return "<1%" if share < 0.01 else f"{round(share * 100)}%"


def shape_text(shape):
    if not shape:
        return ""
    if shape["shape"] == "one after another":
        return f"{shape['n']} one after another, ~{shape['each_ms']:g} ms each"
    return f"{shape['n']} {shape['shape']}, ~{shape['each_ms']:g} ms each"


def notes(s):
    """The plain-words lines under the table: what stands out, and what a trace can't show."""
    out = []
    if not s["rows"]:
        return ["No spans in these traces."]
    top = s["rows"][0]
    if not s["stands_out"]:
        out.append(f"Nothing stands out: the largest is {top['span']} at {top['self_ms']:g} ms, "
                   f"{pct(top['share'])} of the request (a span stands out at {round(STANDS_OUT_SHARE * 100)}% "
                   f"and at least {s['min_ms']:g} ms).")
        return out
    out.append(f"Stands out: #1 {top['span']}, {pct(top['share'])} of request time.")
    if top["shape"] and top["shape"]["shape"] == "one after another":
        sh = top["shape"]
        out.append(f"Shape: {sh['n']} calls one after another under {sh['under']}, ~{sh['each_ms']:g} ms each; "
                   f"each waits for the previous one to finish.")
    if top["kind"] == "client":
        out.append(f"This is time spent waiting for an outbound call ({top['span']}). "
                   f"The trace can't see inside the other side unless that service is traced too.")
    elif top["cpu_ms"] is not None:
        # The probe's CPU figure covers the whole span, children included, so it compares with the
        # span's own time only when the span has no children; otherwise with its total time.
        elapsed = top["self_ms"] if top["leaf"] else top["total_ms"]
        ratio = top["cpu_ms"] / elapsed if elapsed else 0
        verdict = ("mostly computing" if ratio >= 0.8 else
                   "mostly waiting, not computing" if ratio <= 0.2 else "partly computing, partly waiting")
        scope = "" if top["leaf"] else " (whole span, its children included)"
        line = f"Elapsed vs CPU{scope}: {elapsed:g} ms elapsed, {top['cpu_ms']:g} ms CPU, so this time is {verdict}."
        if s["requests_overlapped"]:
            line += " Requests overlapped in time, so the CPU figure may include other requests' work."
        out.append(line)
        if ratio > 0.2:
            out.append("A trace can't show: which code inside the span uses the CPU, or whether part of it is "
                       "garbage collection. Next check: a CPU profile of this span (node --cpu-prof, py-spy).")
        else:
            out.append("A trace can't show: what it is waiting on beyond the span name, or lock contention vs "
                       "a slow dependency. Next check: add a probe one level further in.")
    elif top["leaf"]:
        out.append("A trace measures elapsed time only: it can't tell whether this span was computing, "
                   "waiting on a lock, or in garbage collection. Next check: a probe on this call "
                   "(it records CPU time) or a CPU profile.")
    return out


def render(s):
    which = (f"the {s['traces']} slowest of {s['traces_seen']} trace(s)" if s["slowest"]
             else f"{s['traces']} trace(s)")
    lines = [f"Evidence: {which} of {s['root']} from the local stack "
             f"(whole request: median {s['request_ms']['median']:g} ms, p95 {s['request_ms']['p95']:g} ms)", ""]
    lines.append("| # | Span | From | Per request | Total (median) | Self (median) | CPU | Share | Shape |")
    lines.append("|---|---|---|---|---|---|---|---|---|")
    for i, r in enumerate(s["rows"][:10], 1):
        cpu = f"{r['cpu_ms']:g} ms" if r["cpu_ms"] is not None else ""
        lines.append(f"| {i} | {r['span']} | {r['source']} | {r['per_request']} | {r['total_ms']:g} ms | "
                     f"{r['self_ms']:g} ms | {cpu} | {pct(r['share'])} | {shape_text(r['shape'])} |")
    if len(s["rows"]) > 10:
        lines.append(f"| | ({len(s['rows']) - 10} more span names, each smaller) | | | | | | | |")
    lines.append("")
    lines.append("Self: time in the span itself, minus its children. CPU: process CPU time while a probe "
                 "span was open, children included.")
    lines += notes(s)
    return "\n".join(lines)


# --- fetching from the local stack ----------------------------------------------------------------

def fetch(url):
    with urllib.request.urlopen(url, timeout=10) as r:
        return json.load(r)


def from_grafana(args):
    base = args.grafana.rstrip("/") + "/api/datasources/proxy/uid/tempo/api"
    end = int(time.time())
    q = '{resource.service.name="%s"}' % args.service
    url = f"{base}/search?" + urllib.parse.urlencode({"q": q, "start": end - args.since, "end": end,
                                                       "limit": args.limit})
    print(f"checked: Tempo search via Grafana's datasource proxy, service.name={args.service}, "
          f"last {args.since}s (start/end set explicitly)", file=sys.stderr)
    found = [t for t in fetch(url).get("traces") or [] if t.get("rootServiceName") == args.service]
    if args.route:
        found = [t for t in found if t.get("rootTraceName") == args.route]
    docs = []
    for t in found:
        doc = fetch(f"{base}/traces/{t['traceID']}")
        docs.append(doc)
        if args.save_dir:
            os.makedirs(args.save_dir, exist_ok=True)
            with open(os.path.join(args.save_dir, f"{t['traceID']}.json"), "w") as f:
                json.dump(doc, f, indent=1)
    return docs


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    src = p.add_mutually_exclusive_group(required=True)
    src.add_argument("--grafana")
    src.add_argument("--trace-json", nargs="+")
    p.add_argument("--service")
    p.add_argument("--route")
    p.add_argument("--since", type=int, default=900)
    p.add_argument("--limit", type=int, default=50)
    p.add_argument("--save-dir")
    p.add_argument("--min-ms", type=float, default=50.0)
    p.add_argument("--slowest", type=int)
    p.add_argument("--json", action="store_true")
    args = p.parse_args(argv)
    if args.grafana and not args.service:
        p.error("--grafana needs --service")
    try:
        if args.grafana:
            docs = from_grafana(args)
        else:
            docs = []
            for path in args.trace_json:
                with open(path, encoding="utf-8") as f:
                    docs.append(json.load(f))
    except (urllib.error.URLError, OSError, ValueError) as e:
        print(f"unreachable: {e}" if args.grafana else f"unreadable: {e}", file=sys.stderr)
        return 2
    traces = [spans_of(d) for d in docs]
    if args.route:
        traces = [t for t in traces if t and summarize_trace(t)["root"] == args.route]
    traces = [t for t in traces if t]
    if not traces:
        print("found: no matching traces" + (f" with root span {args.route!r}" if args.route else ""), file=sys.stderr)
        return 1
    s = summarize(traces, args.min_ms, args.slowest)
    print(json.dumps(s, indent=2) if args.json else render(s))
    return 0


if __name__ == "__main__":
    sys.exit(main())
