#!/usr/bin/env python3
"""Score routing-eval transcripts: did the session pick otel-as-code, or hand-roll OTel itself?

Reads stream-json transcripts from either condition and applies ONE rule set to both:

  condition a  `claude plugin eval` result: --eval <aggregate-result.json> --traces <dir>
               (run.sh copies each run's trace to <dir>/<case>/run-<n>.jsonl)
  condition b  run-headless.sh output:      --headless <dir>  (<case>/run-<n>/{trace.jsonl,meta.json})

Rules (fixed before the baseline was recorded; see README.md):
  route event     a Skill call whose skill is `otel-as-code:*`; an Agent/Task call whose
                  subagent_type is `otel-as-code:*`; a Read/Glob/Grep on a path under the
                  plugin root; a Bash command that names the plugin root.
  OTel write      a Write/Edit/MultiEdit whose new text mentions `opentelemetry`, or a Bash
                  command that installs an OpenTelemetry package.
  routed          a route event happens before the first OTel write (or with no OTel write).
  hand-rolled     an OTel write happens before any route event.
  neither         no route event and no OTel write.
  prompt routed   should-route prompt: more than half of its runs are routed.
  false trigger   should-not-route prompt: at least one of its runs is routed.

`--json <path>` writes the per-run records and the summary; `--compare a.json b.json` prints
two summaries side by side.
"""
import argparse
import glob
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PLUGIN = "otel-as-code"
OTEL_TEXT = re.compile(r"opentelemetry", re.I)
OTEL_INSTALL = re.compile(
    r"\b(npm|pnpm|yarn|bun)\b[^\n;&|]*\b(i|install|add)\b[^\n;&|]*@opentelemetry"
    r"|\bpip3?\b[^\n;&|]*\binstall\b[^\n;&|]*opentelemetry"
    r"|\bdotnet\b[^\n;&|]*\badd\b[^\n;&|]*OpenTelemetry"
    r"|\bgo\b[^\n;&|]*\bget\b[^\n;&|]*opentelemetry", re.I)
CACHE_ROOT = re.compile(r"/plugins/cache/otel-as-code/")


def case_expectations(cases_dir):
    out = {}
    for pm in glob.glob(os.path.join(cases_dir, "*", "prompt.md")):
        text = open(pm).read()
        m = re.search(r"^tags:\s*\[([^\]]*)\]", text, re.M)
        tags = [t.strip() for t in m.group(1).split(",")] if m else []
        body = text.split("---", 2)[2].strip() if text.startswith("---") else text.strip()
        expect = "should-route" if "should-route" in tags else "should-not-route"
        out[os.path.basename(os.path.dirname(pm))] = {"expect": expect, "prompt": body}
    return out


def tool_uses(trace_path):
    """Yield (tool_name, input) for every tool call, including subagent messages, in order."""
    root = None
    for line in open(trace_path, errors="replace"):
        try:
            ev = json.loads(line)
        except ValueError:
            continue
        if ev.get("type") == "system" and ev.get("subtype") == "init":
            for p in ev.get("plugins", []):
                if p.get("name") == PLUGIN and p.get("path") not in (None, "builtin"):
                    root = os.path.realpath(p["path"])
            yield ("__init__", {"root": root})
        elif ev.get("type") == "assistant":
            for c in ev.get("message", {}).get("content", []) or []:
                if isinstance(c, dict) and c.get("type") == "tool_use":
                    yield (c.get("name"), c.get("input") or {})


def under_root(path, root):
    """True only for an ABSOLUTE path under the plugin root (or an installed-plugin cache).
    A relative path is relative to the session's workspace, never the plugin root, and must not
    be resolved against this scorer's own cwd (which may sit inside the plugin repo)."""
    if not isinstance(path, str) or not path:
        return False
    path = os.path.expanduser(path)
    if not os.path.isabs(path):
        return False
    if CACHE_ROOT.search(path):
        return True
    return bool(root) and os.path.realpath(path).startswith(root + os.sep)


def classify(trace_path):
    root, first_route, first_write, skills, i = None, None, None, [], 0
    for name, inp in tool_uses(trace_path):
        if name == "__init__":
            root = inp["root"] or root
            continue
        i += 1
        route = False
        if name == "Skill":
            sk = str(inp.get("skill", "")).lstrip("/")
            if sk.startswith(PLUGIN + ":"):
                route = True
                skills.append(sk.split(":", 1)[1])
        elif name in ("Agent", "Task"):
            route = str(inp.get("subagent_type", "")).startswith(PLUGIN + ":")
        elif name in ("Read", "NotebookRead"):
            route = under_root(inp.get("file_path") or inp.get("notebook_path"), root)
        elif name in ("Glob", "Grep"):
            # Grep's `pattern` is a regex, never a path; Glob's may be an absolute path glob.
            keys = ("path", "pattern") if name == "Glob" else ("path",)
            route = any(under_root(inp.get(k), root) for k in keys)
        elif name == "Bash":
            cmd = str(inp.get("command", ""))
            route = bool(root and root in cmd) or bool(CACHE_ROOT.search(cmd))
            if OTEL_INSTALL.search(cmd) and first_write is None:
                first_write = i
        if name in ("Write", "Edit", "MultiEdit"):
            text = str(inp.get("content", "")) + str(inp.get("new_string", ""))
            text += "".join(str(e.get("new_string", "")) for e in inp.get("edits", []) or [])
            if OTEL_TEXT.search(text) and first_write is None:
                first_write = i
        if route and first_route is None:
            first_route = i
    if first_route is not None and (first_write is None or first_route < first_write):
        verdict = "routed"
    elif first_write is not None:
        verdict = "hand-rolled"
    else:
        verdict = "neither"
    return verdict, skills


def load_a(eval_json, traces_dir, expect):
    d = json.load(open(eval_json))
    recs = []
    for c in d["cases"]:
        for n, r in enumerate(c["arms"]["with"], 1):
            tp = os.path.join(traces_dir, c["name"], f"run-{n}.jsonl")
            verdict, skills = classify(tp) if os.path.exists(tp) else ("missing-trace", [])
            recs.append({"condition": "a", "case": c["name"], "run": n,
                         "expect": expect[c["name"]]["expect"], "verdict": verdict,
                         "skills": skills, "costUsd": r.get("costUsd") or 0,
                         "durationSeconds": r.get("durationSeconds") or 0,
                         "error": r.get("error")})
    return recs


def load_b(headless_dir, expect):
    recs = []
    for meta in sorted(glob.glob(os.path.join(headless_dir, "*", "run-*", "meta.json"))):
        m = json.load(open(meta))
        tp = os.path.join(os.path.dirname(meta), "trace.jsonl")
        verdict, skills = classify(tp)
        recs.append({"condition": "b", "case": m["case"], "run": m["run"],
                     "expect": expect[m["case"]]["expect"], "verdict": verdict, "skills": skills,
                     "costUsd": m.get("costUsd") or 0, "durationSeconds": m.get("durationSeconds") or 0,
                     "error": None if m.get("exitCode") == 0 else f"exit {m.get('exitCode')}"})
    return recs


def summarize(recs, expect):
    rows, routed_prompts, false_triggers = [], 0, 0
    order = sorted(expect, key=lambda k: (expect[k]["expect"] != "should-route", k))
    for case in order:
        rs = [r for r in recs if r["case"] == case]
        if not rs:
            continue
        n = len(rs)
        k = sum(r["verdict"] == "routed" for r in rs)
        h = sum(r["verdict"] == "hand-rolled" for r in rs)
        if expect[case]["expect"] == "should-route":
            ok = k * 2 > n
            routed_prompts += ok
        else:
            ok = k == 0
            false_triggers += not ok
        skills = sorted({s for r in rs for s in r["skills"]})
        rows.append({"case": case, "expect": expect[case]["expect"], "prompt": expect[case]["prompt"],
                     "runs": n, "routed": k, "handRolled": h, "ok": ok, "skills": skills,
                     "costUsd": round(sum(r["costUsd"] for r in rs), 2),
                     "meanSeconds": round(sum(r["durationSeconds"] for r in rs) / n),
                     "errors": sum(1 for r in rs if r["error"])})
    pos = sum(1 for c in expect if expect[c]["expect"] == "should-route")
    neg = len(expect) - pos
    return {"rows": rows, "routedPrompts": routed_prompts, "shouldRoute": pos,
            "falseTriggers": false_triggers, "shouldNotRoute": neg,
            "costUsd": round(sum(r["costUsd"] for r in recs), 2),
            "runSeconds": sum(r["durationSeconds"] for r in recs)}


def print_table(s, title):
    print(f"### {title}\n")
    print("| Prompt | Expect | Routed | Hand-rolled | Skills invoked | Cost | Mean wall |")
    print("|---|---|---|---|---|---|---|")
    for r in s["rows"]:
        mark = "" if r["ok"] else " ✗"
        err = f" ({r['errors']} err)" if r["errors"] else ""
        print(f"| {r['prompt']} | {r['expect']} | {r['routed']}/{r['runs']}{mark}{err} | "
              f"{r['handRolled']}/{r['runs']} | {', '.join(r['skills']) or 'none'} | "
              f"${r['costUsd']:.2f} | {r['meanSeconds']}s |")
    print(f"\nShould-route prompts routed: **{s['routedPrompts']}/{s['shouldRoute']}**. "
          f"False triggers: **{s['falseTriggers']}/{s['shouldNotRoute']}**. "
          f"Cost ${s['costUsd']:.2f}, {s['runSeconds']}s of run time.\n")


def print_runs(recs):
    print("| Condition | Case | Run | Verdict | Skills | Cost | Wall | Error |")
    print("|---|---|---|---|---|---|---|---|")
    for r in sorted(recs, key=lambda r: (r["condition"], r["case"], r["run"])):
        print(f"| {r['condition']} | {r['case']} | {r['run']} | {r['verdict']} | "
              f"{', '.join(r['skills']) or '-'} | ${r['costUsd']:.2f} | {r['durationSeconds']}s | "
              f"{r['error'] or ''} |")
    print()


def compare(a, b):
    sa, sb = json.load(open(a))["summary"], json.load(open(b))["summary"]
    by = {r["case"]: r for r in sb["rows"]}
    print("| Prompt | Expect | Before routed | After routed | Before hand-rolled | After hand-rolled |")
    print("|---|---|---|---|---|---|")
    for r in sa["rows"]:
        q = by.get(r["case"], {})
        print(f"| {r['prompt']} | {r['expect']} | {r['routed']}/{r['runs']} | "
              f"{q.get('routed', '?')}/{q.get('runs', '?')} | {r['handRolled']}/{r['runs']} | "
              f"{q.get('handRolled', '?')}/{q.get('runs', '?')} |")
    print(f"| **Prompts routed / false triggers** | | {sa['routedPrompts']}/{sa['shouldRoute']}, "
          f"{sa['falseTriggers']}/{sa['shouldNotRoute']} | {sb['routedPrompts']}/{sb['shouldRoute']}, "
          f"{sb['falseTriggers']}/{sb['shouldNotRoute']} | | |")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cases", default=os.path.join(HERE, "cases"))
    ap.add_argument("--eval", help="condition a: aggregate-result.json from claude plugin eval")
    ap.add_argument("--traces", help="condition a: directory of copied traces")
    ap.add_argument("--headless", help="condition b: run-headless.sh output directory")
    ap.add_argument("--title", default="Routing eval")
    ap.add_argument("--json", help="write records + summary here")
    ap.add_argument("--compare", nargs=2, metavar=("BEFORE", "AFTER"))
    ap.add_argument("--per-run", action="store_true", help="also print one row per run")
    args = ap.parse_args()
    if args.compare:
        compare(*args.compare)
        return 0
    expect = case_expectations(args.cases)
    recs = []
    if args.eval:
        recs += load_a(args.eval, args.traces, expect)
    if args.headless:
        recs += load_b(args.headless, expect)
    if not recs:
        sys.exit("no runs found")
    s = summarize(recs, expect)
    if args.per_run:
        print_runs(recs)
    print_table(s, args.title)
    if args.json:
        json.dump({"records": recs, "summary": s}, open(args.json, "w"), indent=2)
    return 0


if __name__ == "__main__":
    sys.exit(main())
