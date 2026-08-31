#!/usr/bin/env bash
# tests/e2e/plan-local.sh — #4: run `terraform plan` for one backend against your creds.
# Local only (needs real vendor credentials in the environment). Not part of CI.
set -euo pipefail
cd "$(dirname "$0")/../.."

VENDOR="${1:-}"
[ -n "$VENDOR" ] || { echo "usage: plan-local.sh <vendor>   (one of: $(paste -sd'|' backends.txt))" >&2; exit 2; }
grep -qxF "$VENDOR" backends.txt || { echo "unknown vendor '$VENDOR' (see backends.txt)" >&2; exit 2; }

SNAP="tests/snapshots/$VENDOR/main.tf.snap"
[ -f "$SNAP" ] || { echo "no snapshot for $VENDOR at $SNAP" >&2; exit 2; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
cp "$SNAP" "$WORK/main.tf"
echo "Running terraform plan for $VENDOR (credentials must be in your environment)…"
terraform -chdir="$WORK" init -input=false
terraform -chdir="$WORK" plan -input=false
