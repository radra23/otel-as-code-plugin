#!/usr/bin/env bash
# scripts/build-directory.sh <out-dir>
# Builds the slim plugin folder that Anthropic's plugin directory is pointed at (the `directory`
# branch). People who install from the directory get only the submitted folder, and the
# directory reviews everything in it, so it carries exactly what the plugin uses at run time and
# none of the development tree (fixtures, tests, evals, CI, the Codex bridge, docs).
#
# What "run time" means is checked, not assumed: tests/directory-build.test.sh fails if any
# ${CLAUDE_PLUGIN_ROOT}/<path> the shipped files name is missing from the build. Installing from
# this repo's own marketplace is unaffected; that still uses the full tree.
set -euo pipefail
OUT=${1:?usage: build-directory.sh <out-dir>}
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_URL="https://github.com/radra23/otel-as-code-plugin"

[ -e "$OUT" ] && [ -n "$(ls -A "$OUT" 2>/dev/null)" ] && { echo "build-directory: $OUT is not empty" >&2; exit 1; }
mkdir -p "$OUT/.claude-plugin" "$OUT/hooks" "$OUT/scripts"

# Tracked files only, so a local __pycache__ or scratch file can never ship.
(cd "$ROOT" && git ls-files -z -- commands agents skills) | (cd "$ROOT" && rsync -a --from0 --files-from=- ./ "$OUT/")

# The manifest and its icon; not marketplace.json, which would make the folder read as a
# marketplace rather than one plugin.
cp "$ROOT/.claude-plugin/plugin.json" "$ROOT/.claude-plugin/icon.png" "$OUT/.claude-plugin/"
# Claude Code hooks only; hooks/codex/ is the Codex bridge and runs from a repo checkout.
for f in hooks.json write-guard.sh semconv-lint.sh session-summary.sh otel-paths.sh otel-force-match.py; do
  cp "$ROOT/hooks/$f" "$OUT/hooks/"
done
# Scripts the commands run through ${CLAUDE_PLUGIN_ROOT}; drift_check.py is CI-only.
cp "$ROOT/scripts/lgtm_check.py" "$ROOT/scripts/write_context.py" "$OUT/scripts/"
cp "$ROOT/backends.txt" "$ROOT/LICENSE" "$ROOT/SECURITY.md" "$OUT/"

# README: the directory shows it as the listing. Relative links point at files this folder does
# not carry, so they become links into the full repository.
python3 - "$ROOT/README.md" "$OUT/README.md" "$REPO_URL" <<'PY'
import re, sys
src, dst, repo = sys.argv[1:4]
LOCAL = r"(?![a-z]+:|#|/)([^)\s]+)"
s = open(src, encoding="utf-8").read()
# Images first (served raw), then every other link target, including a badge whose text is itself
# an image, as in [![License](...)](LICENSE).
s = re.sub(r"(!\[[^\]]*\])\(" + LOCAL + r"\)", lambda m: f"{m.group(1)}({repo}/raw/main/{m.group(2)})", s)
s = re.sub(r"\]\(" + LOCAL + r"\)", lambda m: f"]({repo}/blob/main/{m.group(1)})", s)
open(dst, "w", encoding="utf-8").write(s)
PY
