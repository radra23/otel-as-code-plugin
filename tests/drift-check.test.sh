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
check("node pins count >= 6", len(np) >= 6)
pp = dict(d.python_pins())
check("python pins parsed (opentelemetry-sdk)", "opentelemetry-sdk" in pp)
tf = dict(d.tf_pins())
check("tf provider pins parsed (all 4 vendors)", len(tf) == 4 and "grafana/grafana" in tf)
check("semconv pin parsed (1.44.0)", d.semconv_pin() == "1.44.0")

check("behind: 1.27.0 < 1.37.0", d.behind("1.27.0", "1.37.0"))
check("not behind: 2.8.0 == 2.8.0", not d.behind("2.8.0", "2.8.0"))
check("behind: ^0.219.0 < 0.230.0", d.behind("0.219.0", "0.230.0"))
check("behind_major: ~>3.0 < 4.0.0", d.behind_major("~> 3.0", "4.0.0"))
check("not behind_major: ~>3.0 vs 3.30.0 (within constraint)", not d.behind_major("~> 3.0", "3.30.0"))

print()
print("Results:", "OK" if ok else "FAILED")
sys.exit(0 if ok else 1)
EOF
