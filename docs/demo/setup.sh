#!/usr/bin/env bash
# docs/demo/setup.sh
# Creates a fresh, committed copy of the checkout-api fixture to record the README demo in.
# Usage: bash docs/demo/setup.sh [target-dir]    (default: ~/otel-demo)
set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TARGET="${1:-$HOME/otel-demo}"
FIXTURE="$PLUGIN_ROOT/fixtures/nodejs-greenfield"

if [ -e "$TARGET" ]; then
  echo "setup: $TARGET already exists. Remove it or pass another path." >&2
  exit 1
fi

mkdir -p "$TARGET"
cp "$FIXTURE/index.js" "$FIXTURE/package.json" "$FIXTURE/Dockerfile" "$TARGET/"
printf 'node_modules/\n' > "$TARGET/.gitignore"

cd "$TARGET"
# Pre-install express so the only install on camera is the one /otel-instrument asks for.
npm install --no-audit --no-fund --silent
git init -q
git add -A
git -c user.name=demo -c user.email=demo@example.invalid commit -qm "checkout-api"

cat <<EOF
setup: demo repo ready at $TARGET

Next:
  cd $TARGET
  asciinema rec --capture-input --cols 100 --rows 32 demo.cast   # asciinema 2.x: --stdin
Then follow the shot list in docs/demo/README.md, and render with:
  bash $PLUGIN_ROOT/docs/demo/render.sh $TARGET/demo.cast
EOF
