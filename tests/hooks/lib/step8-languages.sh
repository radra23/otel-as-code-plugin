# tests/hooks/lib/step8-languages.sh
# Reads /otel-instrument's Step 8 by meaning, not wording (#259): which languages it says export
# nowhere until an endpoint is set, and which it says export over OTLP/HTTP on :4318. A check asks
# whether a language is in a list, so adding another language to the sentence breaks nothing.
#   step8_languages silent [file]   one name per line, e.g. ".NET"
#   step8_languages http   [file]
step8_languages() {
  python3 - "$1" "${2:-commands/otel-instrument.md}" <<'PY'
import re, sys
kind, path = sys.argv[1], sys.argv[2]
text = open(path, encoding="utf-8").read()
m = re.search(r"^## Step 8\b(.*?)(?=^## |\Z)", text, re.S | re.M)
if not m:
    sys.exit("step8_languages: Step 8 was not found")
step = m.group(1)
if kind == "silent":
    said = re.search(r"([\w.]+(?:/[\w.]+)+) code defaults every exporter to `none`", step)
    names = said.group(1).split("/") if said else []
elif kind == "http":
    names = re.findall(r"([\w.]+) exports over OTLP/\*\*HTTP\*\* on `:4318`", step)
else:
    sys.exit(f"step8_languages: unknown list {kind!r}")
if not names:
    sys.exit(f"step8_languages: Step 8 names no {kind} languages")
print("\n".join(names))
PY
}
