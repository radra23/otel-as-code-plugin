#!/usr/bin/env python3
"""Upstream drift check for otel-as-code.

Compares the versions this plugin pins / generates against the latest upstream releases and
reports what is behind:
  - OTel semconv spec        (SEMCONV_VERSION vs the semantic-conventions GitHub release)
  - Node OTel SDK packages   (agents/instrumentation-gen.md pins vs the npm registry)
  - Python OTel SDK packages (agents/instrumentation-gen.md pins vs PyPI)
  - .NET OTel SDK packages   (agents/instrumentation-gen.md pins vs NuGet, and whether a newer
                              release still ships the golden project's TargetFramework — #229)
  - Rust OTel crates          (agents/instrumentation-gen.md pins vs crates.io)
  - PHP OTel packages         (agents/instrumentation-gen.md pins vs Packagist)
  - Terraform providers       (snapshot required_providers major vs the Terraform registry)
  - OTel Collector (contrib)  (tests/collector-validate.sh pin vs the collector-releases GitHub release)
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


def fetch_text(url):
    out = subprocess.run(
        ["curl", "-fsSL", "--max-time", "20", "-H", "User-Agent: otel-as-code-drift-check", url],
        capture_output=True, text=True, timeout=30,
    )
    if out.returncode != 0:
        raise RuntimeError(f"curl exit {out.returncode}")
    return out.stdout


def latest_npm(pkg):
    return fetch_json("https://registry.npmjs.org/" + urllib.parse.quote(pkg, safe="@") + "/latest")["version"]


def latest_pypi(pkg):
    return fetch_json(f"https://pypi.org/pypi/{pkg}/json")["info"]["version"]


def latest_packagist(pkg):
    """Highest stable version on Packagist. The p2 API returns versions descending with no
    separate stable/dev split, but dev branches (`dev-main`) sort first alphabetically despite
    not being releases — filter those out before taking the first real one (#117)."""
    versions = fetch_json(f"https://repo.packagist.org/p2/{pkg}.json")["packages"][pkg]
    for v in versions:
        if not v["version"].startswith("dev-"):
            return v["version"]
    return None


def latest_crate(name):
    return fetch_json(f"https://crates.io/api/v1/crates/{name}")["crate"]["max_stable_version"]


def latest_nuget(pkg):
    """Highest STABLE version on nuget.org. The flat-container index lists every version ever
    published, ascending, with no "latest" field and no stable/prerelease split (unlike npm's
    /latest or crates.io's max_stable_version) — prerelease versions carry a `-` suffix
    (`1.21.0-rc.1`), so filter those out before taking the last one."""
    versions = fetch_json(f"https://api.nuget.org/v3-flatcontainer/{pkg.lower()}/index.json")["versions"]
    stable = [v for v in versions if "-" not in v]
    return stable[-1] if stable else versions[-1]


def latest_tf(source):  # e.g. "grafana/grafana"
    return fetch_json(f"https://registry.terraform.io/v1/providers/{source}")["version"]


def latest_collector():
    return fetch_json("https://api.github.com/repos/open-telemetry/opentelemetry-collector-releases/releases/latest")["tag_name"].lstrip("v")


def latest_semconv():
    return fetch_json("https://api.github.com/repos/open-telemetry/semantic-conventions/releases/latest")["tag_name"].lstrip("v")


# --- .NET target-framework support (#229) -----------------------------------
# A version comparison cannot see this failure. OpenTelemetry 1.21.0 dropped its net8.0/net9.0
# assets (both frameworks left support on 2026-11-10), so a net8.0 project restores the
# .NETStandard2.x build instead. That compiles — NuGet's nearest-TFM fallback is silent, and
# the only build-time signal is the SDK's "doesn't support net8.0" warning on the transitive
# Microsoft.Extensions 11.0 packages — but the asset was compiled with different `#if NET`
# branches: the OTLP exporter sets HTTP/2 `RequestVersionExact` only under `#if NET`, so on
# .NET 8 the netstandard build sends gRPC over HTTP/1.1 and every export fails without a word.
# A routine drift bump shipped exactly that; the e2e trace-flow job caught it. So a release that
# no longer ships the golden's TargetFramework is reported as *do not bump*, not plain BEHIND.
_NATIVE_TFM = re.compile(r"^\.?(?:net|netcoreapp)(\d+)\.(\d+)$", re.I)


def nuget_tfm_groups(pkg, version):
    """Target frameworks one package version declares dependency groups for (`net8.0`,
    `.NETStandard2.0`, ...), from the flat-container nuspec — the document NuGet itself
    restores from. The OTel packages declare one group per lib/ TFM, empty groups included."""
    import xml.etree.ElementTree as ET
    root = ET.fromstring(fetch_text(
        f"https://api.nuget.org/v3-flatcontainer/{pkg.lower()}/{version}/{pkg.lower()}.nuspec"))
    return sorted({el.get("targetFramework") for el in root.iter()
                   if el.tag.rsplit("}", 1)[-1] == "group" and el.get("targetFramework")})


def dotnet_tfm():
    """The golden project's TargetFramework — what the generated output is verified against."""
    m = re.search(r"<TargetFramework>(net\d+\.\d+)</TargetFramework>",
                  _read("tests/snapshots/instrument/dotnet/checkout-api.csproj"))
    return m.group(1) if m else None


def supports_tfm(groups, tfm):
    """True when a project targeting `tfm` selects a native .NET asset from a package that
    declares `groups`; False when it would fall back to .NETStandard/.NETFramework; None when
    there is nothing to judge (no groups, or a TFM shape this does not model). NuGet picks the
    NEAREST compatible group, so any native `netN.M` at or below the project's counts."""
    want = _NATIVE_TFM.match(tfm or "")
    if not want or not groups:
        return None
    w = (int(want.group(1)), int(want.group(2)))
    for g in groups:
        m = _NATIVE_TFM.match(g or "")
        if m and (int(m.group(1)), int(m.group(2))) <= w:
            return True
    return False


def tfm_verdict(pkg, version, tfm, groups_fn=None):
    """'ok' | 'drops' | 'unchecked: <why>' for one package version against the golden TFM.
    Unavailable data is 'unchecked' — reported as not checked, never as a finding."""
    groups, err = safe(groups_fn or nuget_tfm_groups, pkg, version)
    if err:
        return f"unchecked: {err}"
    v = supports_tfm(groups, tfm)
    if v is None:
        return "unchecked: no dependency groups"
    return "ok" if v else "drops"


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


def behind_compatible(pinned, latest):
    """A release exists outside what Cargo's default (caret) requirement accepts: pins like
    `0.33` take every 0.33.x, so only a newer 0.x minor (or a newer major from 1.0 on) is drift."""
    p, l = ver_tuple(pinned), ver_tuple(latest)
    if not p or not l:
        return False
    n = 2 if p[0] == 0 and len(p) > 1 else 1
    p, l = _pad(p, l)
    return l[:n] > p[:n]


# --- parse the plugin's pinned versions -------------------------------------
def _read(path):
    return open(os.path.join(ROOT, path), encoding="utf-8").read()


def node_pins():
    return re.findall(r'"(@opentelemetry/[^"]+)":\s*"\^?([0-9][^"]*)"', _read("agents/instrumentation-gen.md"))


def python_pins():
    return re.findall(r'"(opentelemetry-[^">=]+)>=([0-9][^"]*)"', _read("agents/instrumentation-gen.md"))


def dotnet_pins():
    """(package, version) for each `dotnet add package <id>  # <version>` line in the .NET
    section of instrumentation-gen.md — the comment carries the pin, since `dotnet add` itself
    takes no version argument in the generated command. #184: this plugin pinned .NET packages
    but had no NuGet source, so they were invisible to every drift report."""
    return re.findall(
        r"dotnet add package (OpenTelemetry\.[A-Za-z.]+)\s+#\s*([0-9][0-9.]*)",
        _read("agents/instrumentation-gen.md"))


def php_pins():
    """(package, version) for each `"open-telemetry/<pkg>": "^<version>"` line in the PHP
    section of instrumentation-gen.md — the Packagist vendor namespace IS the distinctive
    prefix, same role @opentelemetry/ plays for node_pins() above (#117)."""
    return re.findall(r'"(open-telemetry/[^"]+)":\s*"\^?([0-9][^"]*)"', _read("agents/instrumentation-gen.md"))


def rust_pins():
    """(crate, requirement) for each line of the marked Cargo.toml block in the Rust section of
    instrumentation-gen.md, which is the one place the Rust pins are written down."""
    text = _read("agents/instrumentation-gen.md")
    m = re.search(r"# otel-as-code: begin[^\n]*\n(.*?)# otel-as-code: end", text, re.S)
    if not m:
        return []
    pins = []
    for line in m.group(1).splitlines():
        line = line.split("#", 1)[0]
        v = re.match(r'\s*([A-Za-z0-9_-]+)\s*=\s*(?:"([^"]+)"|\{[^}]*?version\s*=\s*"([^"]+)")', line)
        if v:
            pins.append((v.group(1), v.group(2) or v.group(3)))
    return pins


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


def collector_pins():
    """Every place the Collector version is pinned, keyed by file. The script default is the
    one the drift row reports; the test suite asserts the others agree with it."""
    return {
        "tests/collector-validate.sh": re.search(r'OTELCOL_VERSION:-([0-9.]+)', _read("tests/collector-validate.sh")),
        ".github/workflows/ci.yml": re.search(r'OTELCOL_VERSION:\s*"([0-9.]+)"', _read(".github/workflows/ci.yml")),
        "tests/e2e/docker-compose.yml": re.search(r'otel/opentelemetry-collector-contrib:([0-9.]+)', _read("tests/e2e/docker-compose.yml")),
    }


def collector_pin():
    m = collector_pins()["tests/collector-validate.sh"]
    return m.group(1) if m else None


def semconv_pin():
    m = re.search(r"SEMCONV_VERSION:\s*([0-9.]+)", _read("skills/semconv-discipline/SKILL.md"))
    return m.group(1) if m else None


# --- report -----------------------------------------------------------------
def main():
    rows, warnings = [], []

    def add(component, pinned, latest, err, cmp=behind, note=""):
        # `note` qualifies a BEHIND verdict (the .NET TFM check below); it is appended to the
        # status cell and the warning line so the summary and the issue carry the same message.
        if err or latest is None:
            status = f"? ({err or 'no data'})"
        elif pinned and cmp(pinned, latest):
            status = "BEHIND" + note
            warnings.append(f"{component}: pinned {pinned}, latest {latest}{note}")
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
    tfm = dotnet_tfm()
    for pkg, pinned in dotnet_pins():
        latest, err = safe(latest_nuget, pkg)
        note = ""
        if tfm and not err and latest and pinned and behind(pinned, latest):
            verdict = tfm_verdict(pkg, latest, tfm)
            if verdict == "drops":
                note = f" — {latest} drops {tfm}; do not bump (#229)"
            elif verdict.startswith("unchecked"):
                note = f" ({tfm} support {verdict})"
        add(f"nuget {pkg}", pinned, latest, err, note=note)
        # The PIN is judged too: this is the exact state the drift bump left the repo in, and
        # it must read as a finding on the very next run rather than as "current".
        if tfm and pinned and tfm_verdict(pkg, pinned, tfm) == "drops":
            c, p, l, st = rows[-1]
            rows[-1] = (c, p, l, f"PINNED {pinned} drops {tfm} (#229)")
            warnings.append(
                f"nuget {pkg}: pinned {pinned} ships no {tfm} asset — a {tfm} project restores the "
                f"netstandard build, whose OTLP/gRPC export fails silently (#229); pin the last "
                f"release with a {tfm} group, or move the golden TargetFramework")
    for crate, pinned in rust_pins():
        latest, err = safe(latest_crate, crate)
        add(f"crates.io {crate}", pinned, latest, err, cmp=behind_compatible)
    for pkg, pinned in php_pins():
        latest, err = safe(latest_packagist, pkg)
        add(f"packagist {pkg}", pinned, latest, err)
    for source, pinned in tf_pins():
        latest, err = safe(latest_tf, source)
        add(f"tf {source}", pinned, latest, err, cmp=behind_major)
    latest, err = safe(latest_collector)
    add("otelcol-contrib (Collector)", collector_pin(), latest, err)

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
    rust_note = ("\n\n_The Rust crates move as a group: every `opentelemetry*` crate shares one minor and "
                 "`tracing-opentelemetry` sits one minor ahead. Bump them together, once all have "
                 "released, then regenerate `tests/snapshots/instrument/rust/Cargo.lock`._"
                 if any(w.startswith("crates.io") for w in warnings) else "")
    tfm_note = ("\n\n_A NuGet row marked **drops " + (dotnet_tfm() or "the golden TFM") + "** is not a bump "
                "target: that release ships no asset for the golden project's TargetFramework, and the "
                ".NETStandard fallback compiles but exports nothing over OTLP/gRPC (#229). It stays listed so "
                "the gap is visible; it clears when the golden TargetFramework moves to a framework that "
                "release supports, re-proven by the live e2e trace-flow job._"
                if any("drops" in w for w in warnings) else "")
    summary = (f"**{len(warnings)} item(s) need attention.** Bump the pins, regenerate the "
               f"affected snapshots, correct any guidance finding, and re-validate.{rust_note}{tfm_note}") if warnings \
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
