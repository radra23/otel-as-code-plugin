#!/usr/bin/env bash
# docs/demo/render.sh
# Turns a recorded demo.cast into docs/demo.gif: compress the waiting, render with agg,
# then shrink with gifsicle if it is installed.
# Usage: bash docs/demo/render.sh path/to/demo.cast [extra compress-cast.py flags]
# Needs: python3, agg (brew install agg). Optional: gifsicle (brew install gifsicle).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$HERE/../demo.gif"
CAST="${1:?usage: render.sh path/to/demo.cast [compress-cast flags]}"
shift

command -v agg >/dev/null || { echo "render: agg not found (brew install agg)" >&2; exit 1; }

TMP="$(mktemp -t demo-compressed.XXXXXX).cast"
trap 'rm -f "$TMP"' EXIT

python3 "$HERE/compress-cast.py" "$CAST" "$TMP" "$@"

# --last-frame-duration holds the span output on screen before the GIF loops.
agg --theme monokai --font-size 16 --fps-cap 15 --last-frame-duration 6 "$TMP" "$OUT"

if command -v gifsicle >/dev/null; then
  gifsicle -O3 --lossy=60 --batch "$OUT"
fi

du -h "$OUT" | awk '{print "render: wrote docs/demo.gif (" $1 ")"}'
