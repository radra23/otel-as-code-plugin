#!/usr/bin/env python3
"""Upstream drift check for otel-as-code.

Compares the versions this plugin pins / generates against the latest upstream releases and
reports what is behind:
  - OTel semconv spec        (SEMCONV_VERSION vs the semantic-conventions GitHub release)
  - Node OTel SDK packages   (agents/instrumentation-gen.md pins vs the npm registry)
  - Python OTel SDK packages (agents/instrumentation-gen.md pins vs PyPI)
  - Terraform providers       (snapshot required_providers major vs the Terraform registry)

Informational: always exits 0. Drift is reported as `::warning::` lines plus a markdown table
written to $GITHUB_STEP_SUMMARY (when set). Run locally: `python3 scripts/drift_check.py`.
"""
import json
import os
import re
import subprocess
import sys
import urllib.parse

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))


# --- upstream lookups -------------------------------------------------------
def fetch_json(url):
    # curl (present on CI runners and dev machines) — avoids Python's platform-dependent
    # SSL/CA-bundle issues. -f => non-zero exit on HTTP errors.
    out = subprocess.run(
        ["curl", "-fsSL", "--max-time", "20", "-H", "User-Agent: otel-as-code-drift-check", url],
        capture_output=True, text=True, timeout=30,
    )
    if out.returncode != 0:
        raise RuntimeError(f"curl exit {out.returncode}")
    return json.loads(out.stdout)


def latest_npm(pkg):
    return fetch_json("https://registry.npmjs.org/" + urllib.parse.quote(pkg, safe="@") + "/latest")["version"]


def latest_pypi(pkg):
    return fetch_json(f"https://pypi.org/pypi/{pkg}/json")["info"]["version"]


def latest_tf(source):  # e.g. "grafana/grafana"
    return fetch_json(f"https://registry.terraform.io/v1/providers/{source}")["version"]


def latest_semconv():
    return fetch_json("https://api.github.com/repos/open-telemetry/semantic-conventions/releases/latest")["tag_name"].lstrip("v")


def safe(fn, *a):
    try:
        return fn(*a), None
    except Exception as e:  # network/parse failures shouldn't crash the whole report
        return None, type(e).__name__


# --- version comparison -----------------------------------------------------
def ver_tuple(s):
    return tuple(int(n) for n in re.findall(r"\d+", s or ""))


def _pad(a, b):
    n = max(len(a), len(b))
    return a + (0,) * (n - len(a)), b + (0,) * (n - len(b))


def behind(pinned, latest):
    """latest strictly newer than pinned across the full numeric version."""
    p, l = ver_tuple(pinned), ver_tuple(latest)
    if not p or not l:
        return False
    p, l = _pad(p, l)
    return l > p


def behind_major(pinned, latest):
    """A newer MAJOR exists than the pin's constraint allows (for `~>`-style provider pins)."""
    p, l = ver_tuple(pinned), ver_tuple(latest)
    return bool(p) and bool(l) and l[0] > p[0]


# --- parse the plugin's pinned versions -------------------------------------
def _read(path):
    return open(os.path.join(ROOT, path), encoding="utf-8").read()


def node_pins():
    return re.findall(r'"(@opentelemetry/[^"]+)":\s*"\^?([0-9][^"]*)"', _read("agents/instrumentation-gen.md"))


def python_pins():
    return re.findall(r'"(opentelemetry-[^">=]+)>=([0-9][^"]*)"', _read("agents/instrumentation-gen.md"))


def tf_pins():
    pins, snap_dir = [], os.path.join(ROOT, "tests", "snapshots")
    for vendor in sorted(os.listdir(snap_dir)):
        snap = os.path.join(snap_dir, vendor, "main.tf.snap")
        if not os.path.isfile(snap):
            continue
        m = re.search(r'source\s*=\s*"([^"]+)"[^}]*?version\s*=\s*"([^"]+)"', open(snap, encoding="utf-8").read(), re.S)
        if m:
            pins.append((m.group(1), m.group(2)))
    return pins


def semconv_pin():
    m = re.search(r"SEMCONV_VERSION:\s*([0-9.]+)", _read("skills/semconv-discipline/SKILL.md"))
    return m.group(1) if m else None


# --- report -----------------------------------------------------------------
def main():
    rows, warnings = [], []

    def add(component, pinned, latest, err, cmp=behind):
        if err or latest is None:
            status = f"? ({err or 'no data'})"
        elif pinned and cmp(pinned, latest):
            status = "BEHIND"
            warnings.append(f"{component}: pinned {pinned}, latest {latest}")
        else:
            status = "current"
        rows.append((component, pinned or "?", latest or "?", status))

    latest, err = safe(latest_semconv)
    add("semconv spec (SEMCONV_VERSION)", semconv_pin(), latest, err)
    for pkg, pinned in node_pins():
        latest, err = safe(latest_npm, pkg)
        add(f"npm {pkg}", pinned, latest, err)
    for pkg, pinned in python_pins():
        latest, err = safe(latest_pypi, pkg)
        add(f"pypi {pkg}", pinned, latest, err)
    for source, pinned in tf_pins():
        latest, err = safe(latest_tf, source)
        add(f"tf {source}", pinned, latest, err, cmp=behind_major)

    table = "\n".join(
        ["| Component | Pinned | Latest | Status |", "|---|---|---|---|"]
        + [f"| {c} | `{p}` | `{l}` | {s} |" for c, p, l, s in rows]
    )
    for w in warnings:
        print(f"::warning::otel-as-code drift — {w}")
    summary = f"**{len(warnings)} component(s) behind upstream.** Bump the pins, regenerate the affected snapshots, and re-validate." if warnings \
        else "**All pinned versions are current.**"
    body = "## otel-as-code upstream drift\n\n" + table + "\n\n" + summary + \
        "\n\n_Generated by the `drift-check` CI job (`scripts/drift_check.py`)._\n"
    print(body)

    # Report body for the CI issue step; drift count for gating (both consumed by ci.yml).
    with open(os.path.join(ROOT, "drift-report.md"), "w", encoding="utf-8") as f:
        f.write(body)
    step_summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if step_summary:
        with open(step_summary, "a", encoding="utf-8") as f:
            f.write(body)
    gh_out = os.environ.get("GITHUB_OUTPUT")
    if gh_out:
        with open(gh_out, "a", encoding="utf-8") as f:
            f.write(f"count={len(warnings)}\n")

    sys.exit(0)  # informational — never fail the build on drift


if __name__ == "__main__":
    main()
