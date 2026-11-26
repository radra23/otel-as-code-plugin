# tests/hooks/lib/maturity-status.sh
# Reads a signal's maturity out of skills/language-maturity by table row, not by sentence (#259):
# the status cell of the `| <Signal> | <status> | ... |` row in the table under the `### <Language>`
# heading (the heading may go on, as in "### Java (OpenTelemetry Java agent)").
#   maturity_status PHP Logs [file]   prints e.g. "Stable"
maturity_status() {
  python3 - "$1" "$2" "${3:-skills/language-maturity/SKILL.md}" <<'PY'
import re, sys
lang, signal, path = sys.argv[1:4]
text = open(path, encoding="utf-8").read()
m = re.search(r"^### " + re.escape(lang) + r"\b[^\n]*\n(.*?)(?=^##|\Z)", text, re.S | re.M)
if not m:
    sys.exit(f"maturity_status: no '### {lang}' section")
row = re.search(r"^\| *" + re.escape(signal) + r" *\| *([^|]*?) *\|", m.group(1), re.M)
if not row:
    sys.exit(f"maturity_status: '### {lang}' has no {signal} row")
print(row.group(1))
PY
}
