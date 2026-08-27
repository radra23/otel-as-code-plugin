#!/usr/bin/env bash
# tests/collector-validate.sh
# #3: validate the golden agent Collector config with a pinned otelcol-contrib.
# Downloads the binary (checksum-verified) if absent or stale. Sets a dummy OTLP endpoint
# so env-substitution of an unset var can't produce a false failure. Also enforces the
# memory_limiter-first pipeline-ordering invariant that `otelcol validate` does NOT check.
set -euo pipefail
cd "$(dirname "$0")/.."

OTELCOL_VERSION="${OTELCOL_VERSION:-0.128.0}"
OTELCOL_BIN="${OTELCOL_BIN:-/tmp/otelcol-contrib}"
CONFIG="tests/snapshots/collector/otelcol-agent.yaml.snap"

# ---------------------------------------------------------------------------
# Ordering guard: `otelcol validate` builds the component graph and checks
# schema/config-reference/OTTL-syntax errors, but it does NOT enforce that
# memory_limiter is the first processor in a pipeline (verified empirically
# against 0.128.0 — a reordered config validates cleanly). CLAUDE.md makes
# that ordering a hard constraint, so enforce it here with a plain python3
# regex scan (no YAML lib, no jq — repo convention).
# ---------------------------------------------------------------------------
check_processor_ordering() {
  python3 - "$1" <<'PY'
import re
import sys

path = sys.argv[1]
current_pipeline = None
ok = True
with open(path, encoding="utf-8") as fh:
    for lineno, line in enumerate(fh, start=1):
        m = re.match(r'^    ([A-Za-z_][A-Za-z0-9_]*):\s*$', line)
        if m:
            current_pipeline = m.group(1)
            continue
        m = re.match(r'^\s*processors:\s*\[(.*)\]\s*$', line)
        if not m:
            continue
        items = [x.strip() for x in m.group(1).split(',') if x.strip()]
        if not items or items[0] != "memory_limiter":
            pipeline = current_pipeline or "<unknown>"
            print(
                f"ERROR: {path}:{lineno}: pipeline '{pipeline}' processors "
                f"list does not start with memory_limiter: {items}",
                file=sys.stderr,
            )
            ok = False
sys.exit(0 if ok else 1)
PY
}

# Self-check (committed negative test — replaces the brief's broken Step 4, which
# relied on `otelcol validate` rejecting reordered processors; it doesn't). Prove the
# ordering guard itself has teeth before trusting it against the real golden config.
echo "Self-check: confirming the ordering guard rejects a reordered config..."
bad_tmp="$(mktemp)"
sed 's/memory_limiter, transform, batch/transform, memory_limiter, batch/' "$CONFIG" > "$bad_tmp"
if check_processor_ordering "$bad_tmp" 2>/dev/null; then
  echo "ERROR: ordering self-check did not reject a reordered config — the guard has no teeth" >&2
  rm -f "$bad_tmp"
  exit 1
fi
rm -f "$bad_tmp"
echo "OK: ordering guard correctly rejects memory_limiter-not-first"

echo "Checking memory_limiter-first ordering in $CONFIG..."
check_processor_ordering "$CONFIG"
echo "OK: memory_limiter is first processor in every pipeline"

# ---------------------------------------------------------------------------
# otelcol-contrib acquisition: download to a non-predictable mktemp path and
# verify SHA256 before extracting/installing — a fixed, world-writable
# OTELCOL_BIN path must never be trusted just because a file exists there,
# and a fresh download must never be trusted without integrity verification.
# ---------------------------------------------------------------------------
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# True only if a binary already exists at OTELCOL_BIN AND reports the pinned
# version — a cached binary is never trusted on path/executable-bit alone.
binary_version_ok() {
  [ -x "$OTELCOL_BIN" ] || return 1
  "$OTELCOL_BIN" --version 2>&1 | grep -q "$OTELCOL_VERSION"
}

if ! binary_version_ok; then
  os="$(uname | tr '[:upper:]' '[:lower:]')"
  arch="$(uname -m)"; case "$arch" in x86_64) arch=amd64;; aarch64|arm64) arch=arm64;; esac
  key="${os}_${arch}"

  # Pinned SHA256 checksums for otelcol-contrib_${OTELCOL_VERSION}_<os>_<arch>.tar.gz.
  # The release's own checksums.txt asset
  # (opentelemetry-collector-releases_otelcol-contrib_checksums.txt) is incomplete for
  # this version -- it contains only windows_* entries, an artifact of the release
  # pipeline's per-OS-runner matrix upload overwriting the file -- so these were
  # computed locally after downloading each tarball directly over HTTPS from the
  # canonical GitHub release URL, and cross-checked with both `shasum -a 256` and
  # python3's hashlib. Source release:
  # https://github.com/open-telemetry/opentelemetry-collector-releases/releases/tag/v0.128.0
  case "$key" in
    linux_amd64)  expected_sha="09b1332e29968bacdb7ce564073302ef9567c71919842544b4382f0f15456fd6" ;;
    darwin_arm64) expected_sha="6a5e030ccd6152facb1570a5bb5f794473fac39c6afaa48492f426276c291376" ;;
    darwin_amd64) expected_sha="a1e8cef1a5770b9c7f5a41cff24945faa53bfccbae38512b62a1af119887d7d4" ;;
    *) expected_sha="" ;;
  esac

  if [ -z "$expected_sha" ]; then
    echo "ERROR: no pinned SHA256 checksum for otelcol-contrib ${OTELCOL_VERSION} ($key)." >&2
    echo "Refusing to download and run an unverified binary. Add a pinned hash for this platform." >&2
    exit 1
  fi

  url="https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v${OTELCOL_VERSION}/otelcol-contrib_${OTELCOL_VERSION}_${key}.tar.gz"
  echo "Downloading otelcol-contrib ${OTELCOL_VERSION} ($key)..."
  tmp="$(mktemp -d)"
  curl -fsSL "$url" -o "$tmp/oc.tar.gz"

  actual_sha="$(sha256_of "$tmp/oc.tar.gz")"
  if [ "$actual_sha" != "$expected_sha" ]; then
    echo "ERROR: SHA256 mismatch for otelcol-contrib download." >&2
    echo "  expected: $expected_sha" >&2
    echo "  actual:   $actual_sha" >&2
    rm -rf "$tmp"
    exit 1
  fi

  tar -xzf "$tmp/oc.tar.gz" -C "$tmp" otelcol-contrib
  mv "$tmp/otelcol-contrib" "$OTELCOL_BIN"; chmod +x "$OTELCOL_BIN"; rm -rf "$tmp"

  if ! binary_version_ok; then
    echo "ERROR: checksum-verified download reports an unexpected version (wanted ${OTELCOL_VERSION})." >&2
    exit 1
  fi
fi

# Derive the printed version from the binary itself, not the requested pin --
# the log must not assert a pin that wasn't actually exercised.
actual_version="$("$OTELCOL_BIN" --version 2>&1 | awk '{print $NF}')"

# Dummy endpoint just so ${env:...} resolves to a non-empty value during validate.
OTEL_EXPORTER_OTLP_ENDPOINT="localhost:4317" "$OTELCOL_BIN" validate --config="$CONFIG"
echo "OK: $CONFIG validates against otelcol-contrib ${actual_version}"
