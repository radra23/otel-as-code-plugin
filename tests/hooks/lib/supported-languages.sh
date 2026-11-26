# tests/hooks/lib/supported-languages.sh: sourced by the per-language *-instrument-wiring tests (#259).
# supported_languages prints the languages /otel-instrument supports, one per line, read from its
# Step 4 by meaning rather than wording: the backticked names in the "If it is not ..." condition,
# and the names in the printed "Supported: ..." message. It fails (prints nothing, exits 1) when
# the step is not found, either list is empty, or the two lists differ, so a check built on it
# cannot pass on an empty list or on a message that has drifted from the condition.
supported_languages() {
  python3 - "${1:-commands/otel-instrument.md}" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r"^\d+\. Derive `language` from the selected service\.(.*?)^   - Exit\.", text, re.S | re.M)
if not m:
    sys.exit("supported_languages: the 'Derive `language`' step was not found")
step = m.group(1)
cond = step.split("not supported yet")[0]
said = re.search(r"Supported:(.*?)\.\"", step, re.S)
listed = set(re.findall(r"`([a-z]+)`", cond))
printed = set(re.findall(r"[a-z]+", said.group(1))) - {"or", "and"} if said else set()
if not listed or listed != printed:
    sys.exit(f"supported_languages: condition {sorted(listed)} and message {sorted(printed)} differ")
print("\n".join(sorted(listed)))
PY
}
