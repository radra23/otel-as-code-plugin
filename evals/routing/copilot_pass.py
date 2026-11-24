#!/usr/bin/env python3
"""Condition (c) passes that add up: one results directory per label, any number of passes.

  plan    <label-dir> <cases-dir> <case-glob> <runs> <plugin-version> <copilot-version> <model>
          prints the runs still missing, one "<case-dir> <run>" per line, in run order; exits 3,
          naming what changed, if the label's kept runs were made with another plugin version,
          Copilot version or model (a pass never mixes them)
  total   <cases-dir> <case-glob> <runs>
          prints how many runs a full pass of these cases has
  record  <label-dir> <started> <stopped> <done> <total>
          appends this pass to <label-dir>/meta.json and rebuilds its list of runs
  clear   <label-dir>
          removes every run that is not kept, so the summary scores kept runs only
  reset   <refusal.json>
          prints when the rate limit resets, if the refused call said so

A kept run is one with a scored result: exit 0. A refused run is deleted by run.sh before this
reads the directory, so it can never be scored, and is run again by the next pass.
"""
import fnmatch, glob, json, os, re, sys

# The cases that show whether Copilot stays out of the way come first, then the two whose
# should-route wording is the narrowest, then the rest of the should-route cases.
FIRST = ["diagnose-slow-checkout-with-traces", "checkout-is-slow", "fix-failing-test", "explain-span",
         "span-around-my-function", "test-that-telemetry-stays"]
KEYS = (("pluginVersion", "plugin version"), ("copilotVersion", "Copilot version"), ("model", "model"))


def kept(label_dir):
    out = {}
    for meta in sorted(glob.glob(os.path.join(label_dir, "c", "*", "run-*", "meta.json"))):
        m = json.load(open(meta))
        if m.get("exitCode") == 0:
            out[(m["case"], m["run"])] = m
    return out


def routing_cases(cases_dir, case_glob):
    names = []
    for d in sorted(glob.glob(os.path.join(cases_dir, "*", ""))):
        name = os.path.basename(os.path.dirname(d))
        if fnmatch.fnmatch(name, case_glob) and "tags: [routing" in open(os.path.join(d, "prompt.md")).read():
            names.append(name)
    return sorted(names, key=lambda n: (FIRST.index(n) if n in FIRST else len(FIRST), n))


def plan(label_dir, cases_dir, case_glob, runs, plugin, copilot, model):
    want = {"pluginVersion": plugin, "copilotVersion": copilot, "model": model}
    done = kept(label_dir)
    for key, words in KEYS:
        seen = sorted({str(m.get(key)) for m in done.values()} - {want[key]})
        if seen:
            sys.exit(f"stopped: this label's earlier runs used {words} {', '.join(seen)}, this pass would use "
                     f"{want[key]}. Runs made with different versions are not merged; use a new label.")
    names = routing_cases(cases_dir, case_glob)
    # Every case gets its first run before any case gets its second.
    for n in range(1, int(runs) + 1):
        for name in names:
            if (name, n) not in done:
                print(os.path.join(cases_dir, name), n)


def clear(label_dir):
    import shutil
    for d in glob.glob(os.path.join(label_dir, "c", "*", "run-*", "")):
        meta = os.path.join(d, "meta.json")
        if not (os.path.exists(meta) and json.load(open(meta)).get("exitCode") == 0):
            shutil.rmtree(d)


def total(cases_dir, case_glob, runs):
    print(len(routing_cases(cases_dir, case_glob)) * int(runs))


def record(label_dir, started, stopped, done, total):
    path = os.path.join(label_dir, "meta.json")
    meta = json.load(open(path)) if os.path.exists(path) else {"label": os.path.basename(label_dir), "passes": []}
    runs = sorted(kept(label_dir).values(), key=lambda m: (m["case"], m["run"]))
    meta["passes"].append({"started": started, "stopped": stopped, "runsDone": int(done), "runsTotal": int(total)})
    meta["runs"] = [{k: m.get(k) for k in ("case", "run", "date", "pluginVersion", "copilotVersion", "model",
                                           "premiumRequests", "stoppedAtTurnCap", "durationSeconds")}
                    for m in runs]
    json.dump(meta, open(path, "w"), indent=2)


RESET_KEYS = ("retryAfter", "retry_after", "retryAfterSeconds", "resetAt", "reset_at", "rateLimitReset")


def reset(refusal):
    d = json.load(open(refusal))
    for k in RESET_KEYS:
        if d.get(k) not in (None, ""):
            print(f"{k}: {d[k]}")
            return
    m = re.search(r"(?:try again|retry|resets?)\b[^.]*", str(d.get("errorMessage", "")), re.I)
    print(m.group(0) if m else "the refusal did not say when the limit resets")


if __name__ == "__main__":
    cmd, args = sys.argv[1], sys.argv[2:]
    {"plan": plan, "clear": clear, "total": total, "record": record, "reset": reset}[cmd](*args)
