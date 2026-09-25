#!/usr/bin/env python3
"""Upstream drift check for otel-as-code.

Compares the versions this plugin pins / generates against the latest upstream releases and
reports what is behind:
  - OTel semconv spec        (SEMCONV_VERSION vs the semantic-conventions GitHub release)
  - Node OTel SDK packages   (agents/instrumentation-gen.md pins vs the npm registry)
  - Python OTel SDK packages (agents/instrumentation-gen.md pins vs PyPI)
  - Terraform providers       (snapshot required_providers major vs the Terraform registry)
  - Semconv GUIDANCE          (the OLD->NEW table vs the upstream attribute registry at the pin)

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


# --- semconv attribute registry (first-party, pinned) -----------------------
# The version comparison above catches the PIN falling behind upstream. It cannot catch the
# guidance itself being wrong — a NEW attribute this plugin tells people to migrate TO that
# does not exist at the pinned version, or an OLD one we call deprecated that is in fact still
# current. That is the failure the field report hit (generated comments asserting stability
# facts that were false at the installed version), so it is checked against the registry
# rather than trusted.
#
# Source is the semantic-conventions repo itself at the pinned tag — first-party, versioned,
# no auth, no third-party service in the path.
_REGISTRY_CACHE = {}
_REGISTRY_URL = ("https://raw.githubusercontent.com/open-telemetry/semantic-conventions/"
                 "v{version}/model/{area}/registry.yaml")


def _registry_area(area, version):
    """Attributes defined in one registry area, as {name: {stability, deprecated}}.

    An area that 404s returns {} (no such namespace at this version) — distinct from a
    parse/dependency failure, which raises so the caller can report "unavailable" rather
    than mistaking it for "the guidance is wrong".
    """
    key = (area, version)
    if key not in _REGISTRY_CACHE:
        import yaml  # raises if PyYAML is absent — reported as unavailable, never as drift
        out = subprocess.run(
            ["curl", "-fsSL", "--max-time", "20", _REGISTRY_URL.format(version=version, area=area)],
            capture_output=True, text=True, timeout=30,
        )
        attrs = {}
        if out.returncode == 0:
            doc = yaml.safe_load(out.stdout) or {}
            # Two file shapes coexist at the SAME tag: the older `groups[].attributes[].id`
            # and `file_format: definition/2`'s top-level `attributes[].key`. Handling only
            # one silently reports every attribute in the other as absent — i.e. a false
            # "the guidance is wrong" alarm.
            entries = [a for g in (doc.get("groups") or []) for a in (g.get("attributes") or [])]
            entries += doc.get("attributes") or []
            for a in entries:
                if isinstance(a, dict) and (a.get("id") or a.get("key")):
                    attrs[a.get("id") or a.get("key")] = {
                        "stability": a.get("stability"),
                        "deprecated": bool(a.get("deprecated")),
                    }
        _REGISTRY_CACHE[key] = attrs
    return _REGISTRY_CACHE[key]


def semconv_lookup(name, version):
    """Registry record for one attribute, or None when absent at this version.

    The area is derived from the attribute's own root namespace (`server.address` ->
    model/server/) rather than a hardcoded list of areas, which would rot exactly the way
    this check exists to catch.
    """
    return _registry_area(name.split(".")[0], version).get(name)


_ATTR_TOKEN = re.compile(r"`([a-z][a-z0-9_]*(?:\.[a-z0-9_]+)+)`")


def semconv_table_entries():
    """(old, [new, ...]) for each row of the OLD->NEW tables in the discipline skill.

    A row can name several replacements (`http.target` -> `url.path` + `url.query`), so every
    backticked dotted token in the NEW cell is returned and checked.
    """
    rows = []
    for line in _read("skills/semconv-discipline/SKILL.md").splitlines():
        if not line.startswith("|") or "---" in line:
            continue
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if len(cells) < 2:
            continue
        old, new = _ATTR_TOKEN.findall(cells[0]), _ATTR_TOKEN.findall(cells[1])
        if len(old) == 1 and new:
            rows.append((old[0], new))
    return rows


def semconv_guidance_findings(version):
    """Check every OLD->NEW claim against the registry. Returns a list of human-readable
    findings (empty when the guidance matches upstream)."""
    findings = []
    for old, news in semconv_table_entries():
        for new in news:
            rec = semconv_lookup(new, version)
            if rec is None:
                findings.append(
                    f"`{new}` is offered as the replacement for `{old}`, but no such attribute "
                    f"exists in the registry at v{version}")
            elif rec["stability"] != "stable":
                findings.append(
                    f"`{new}` is offered as a replacement for `{old}`, but is "
                    f"`{rec['stability']}` (not stable) at v{version}")
        rec = semconv_lookup(old, version)
        if rec is not None and rec["stability"] == "stable" and not rec["deprecated"]:
            findings.append(
                f"`{old}` is listed as deprecated, but is still stable and not marked "
                f"deprecated at v{version}")
    return findings


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

    # Guidance accuracy is a different question from version lag and is reported separately:
    # the pin can be perfectly current while the OLD->NEW table still tells people to migrate
    # to an attribute that does not exist. Unavailable (no PyYAML / no network) is reported as
    # "not checked", never as a finding — a broken checker must not read as broken guidance.
    pin = semconv_pin()
    guidance, gerr = safe(semconv_guidance_findings, pin)
    if gerr:
        guidance_md = f"_Not checked ({gerr})._"
    elif guidance:
        warnings.extend(f"semconv guidance: {g}" for g in guidance)
        guidance_md = "\n".join(f"- ⚠ {g}" for g in guidance)
    else:
        guidance_md = (f"_Every OLD→NEW replacement in `semconv-discipline` resolves as a stable "
                       f"attribute in the upstream registry at v{pin}._")

    for w in warnings:
        print(f"::warning::otel-as-code drift — {w}")
    summary = (f"**{len(warnings)} item(s) need attention.** Bump the pins, regenerate the "
               f"affected snapshots, correct any guidance finding, and re-validate.") if warnings \
        else "**All pinned versions are current and the semconv guidance matches the registry.**"
    body = ("## otel-as-code upstream drift\n\n" + table
            + "\n\n### Semconv guidance vs registry\n\n" + guidance_md
            + "\n\n" + summary
            + "\n\n_Generated by the `drift-check` CI job (`scripts/drift_check.py`)._\n")
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
