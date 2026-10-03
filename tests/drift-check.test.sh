#!/usr/bin/env bash
# tests/drift-check.test.sh
# Offline unit test for scripts/drift_check.py — verifies the pin PARSERS still match the
# repo's version formats and the version comparison is correct. No network (that part runs
# only in the scheduled CI job). Guards against a pin-format change silently breaking drift.
set -euo pipefail
cd "$(dirname "$0")/.."

python3 - <<'EOF'
import os, sys
sys.path.insert(0, os.path.join(os.getcwd(), "scripts"))
import drift_check as d

ok = True
def check(name, cond):
    global ok
    print(("PASS" if cond else "FAIL") + ": " + name)
    ok = ok and bool(cond)

np = dict(d.node_pins())
check("node pins parsed (@opentelemetry/sdk-node)", "@opentelemetry/sdk-node" in np and np["@opentelemetry/sdk-node"][0].isdigit())
# Tie the coverage assertion to the golden bootstrap's own dependency list rather than a
# magic count: the drift job must see every package the generator actually emits, and
# legitimately adding or dropping one must not require editing a number here.
import json
golden = json.load(open("tests/snapshots/instrument/nodejs/package.json"))
expected = {k for k in golden["dependencies"] if k.startswith("@opentelemetry/")}
missing = expected - set(np)
check(f"node pins cover every generated dependency ({len(expected)})", not missing)
if missing:
    print("  not found by node_pins():", ", ".join(sorted(missing)))
pp = dict(d.python_pins())
check("python pins parsed (opentelemetry-sdk)", "opentelemetry-sdk" in pp)
# Same idea as the node check above: the golden requirements.txt must pin exactly what the
# generator pins. Before this, a bump that updated one and missed the other went unnoticed.
import re as _re
golden_py = dict(_re.findall(r"^(opentelemetry-[^>=\s]+)>=(\S+)$", open("tests/snapshots/instrument/python/requirements.txt").read(), _re.M))
check(f"python golden requirements match the generator pins ({len(golden_py)})", golden_py and golden_py == pp)
if golden_py != pp:
    print("  generator:", pp); print("  golden:   ", golden_py)
rp = dict(d.rust_pins())
check("rust pins parsed from the generator's marked block (tower with features, plain, table forms)",
      rp.get("opentelemetry") == "0.33" and rp.get("opentelemetry-instrumentation-tower") == "0.19"
      and rp.get("tracing-subscriber") == "0.3")
# The golden crate's Cargo.toml must carry exactly the pinned set, so the drift row watches what
# the golden compiles.
golden_toml = open("tests/snapshots/instrument/rust/Cargo.toml").read()
import tomllib
golden_deps = tomllib.loads(golden_toml)["dependencies"]
golden_rp = {k: (v if isinstance(v, str) else v["version"]) for k, v in golden_deps.items() if k in rp}
check(f"rust pins match the golden crate's Cargo.toml ({len(rp)})", rp and golden_rp == rp)
# The version-group invariant the generator documents: opentelemetry* share a minor and
# tracing-opentelemetry is exactly one minor ahead. A bump that breaks it compiles into two copies
# of the opentelemetry crate (verified: SdkTracer: Tracer is not satisfied).
otel_minors = {d.ver_tuple(v)[1] for k, v in rp.items()
               if k in ("opentelemetry", "opentelemetry_sdk", "opentelemetry-otlp", "opentelemetry-appender-tracing")}
check("rust group: opentelemetry* crates share one minor", len(otel_minors) == 1)
check("rust group: tracing-opentelemetry is one minor ahead",
      len(otel_minors) == 1 and d.ver_tuple(rp.get("tracing-opentelemetry"))[1] == next(iter(otel_minors)) + 1)
tf = dict(d.tf_pins())
check("tf provider pins parsed (all 4 vendors)", len(tf) == 4 and "grafana/grafana" in tf)
check("semconv pin parsed (1.44.0)", d.semconv_pin() == "1.44.0")
cp = d.collector_pins()
check("collector pin parsed from every pinned location", all(cp.values()))
vals = {f: m.group(1) for f, m in cp.items() if m}
check(f"collector pin agrees across {', '.join(sorted(vals))}", len(set(vals.values())) == 1)
if len(set(vals.values())) > 1:
    print("  disagreeing pins:", vals)
check("collector_pin() reports the script default", d.collector_pin() == vals.get("tests/collector-validate.sh"))

check("behind: 1.27.0 < 1.37.0", d.behind("1.27.0", "1.37.0"))
check("not behind: 2.8.0 == 2.8.0", not d.behind("2.8.0", "2.8.0"))
check("behind: ^0.219.0 < 0.230.0", d.behind("0.219.0", "0.230.0"))
check("behind_compatible: 0.33 is not behind 0.33.9 (caret accepts patch releases)", not d.behind_compatible("0.33", "0.33.9"))
check("behind_compatible: 0.33 is behind 0.34.0 (a new 0.x minor is a breaking release)", d.behind_compatible("0.33", "0.34.0"))
check("behind_compatible: 1 is not behind 1.9.0, but is behind 2.0.0", not d.behind_compatible("1", "1.9.0") and d.behind_compatible("1", "2.0.0"))
check("behind_compatible: 0.3 is not behind 0.3.23", not d.behind_compatible("0.3", "0.3.23"))
check("behind_major: ~>3.0 < 4.0.0", d.behind_major("~> 3.0", "4.0.0"))
check("not behind_major: ~>3.0 vs 3.30.0 (within constraint)", not d.behind_major("~> 3.0", "3.30.0"))

# --- semconv guidance check (offline: real table, stubbed registry) ----------------------
# The table parser runs against the REAL skill file — that is the part that breaks when
# someone reformats the tables. The registry side is stubbed, so this stays offline.
rows = dict(d.semconv_table_entries())
check("OLD->NEW table parsed (http.method -> http.request.method)",
      rows.get("http.method") == ["http.request.method"])
check("a row naming two replacements keeps both (http.target)",
      rows.get("http.target") == ["url.path", "url.query"])
check("prose-heavy row still yields its attributes (peer.service)",
      "server.address" in rows.get("peer.service", []))
check("table rows found for every OLD name the skill deprecates", len(rows) >= 10)
# Rows must not be invented from unrelated tables (span-kind, cardinality) in the same file.
check("non-attribute tables are not mistaken for OLD->NEW rows",
      all("." in old for old in rows))

# Teeth: a stubbed registry proves each failure class is actually detected. Without this,
# "no findings" is indistinguishable from a checker that inspects nothing.
_REGISTRY = {
    "http.request.method": {"stability": "stable", "deprecated": False},
    "url.full":            {"stability": "stable", "deprecated": False},
    "service.name":        {"stability": "stable", "deprecated": False},
    "db.query.text":       {"stability": "development", "deprecated": False},
}
d.semconv_lookup = lambda name, version: _REGISTRY.get(name)
d._read = lambda path: """
| OLD (deprecated) | NEW (use this)         | Fix |
|------------------|------------------------|-----|
| `http.method`    | `http.request.method`  | correct row |
| `http.url`       | `url.nonexistent`      | replacement does not exist |
| `service.name`   | `url.full`             | OLD is still stable |
| `db.statement`   | `db.query.text`        | replacement is not stable |
"""
found = d.semconv_guidance_findings("1.44.0")
blob = " | ".join(found)
check("teeth: flags a replacement absent from the registry", "url.nonexistent" in blob)
check("teeth: flags an OLD name that is still stable", "service.name" in blob and "still stable" in blob)
check("teeth: flags a replacement that is not stable", "db.query.text" in blob and "development" in blob)
check("teeth: leaves a correct row alone", "http.request.method" not in blob)
check("teeth: exactly three findings, not a blanket alarm", len(found) == 3)

print()
print("Results:", "OK" if ok else "FAILED")
sys.exit(0 if ok else 1)
EOF
