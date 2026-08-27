#!/usr/bin/env bash
# tests/collector-validate.sh
# #3: validate the golden agent Collector config with a pinned otelcol-contrib.
# Downloads the binary if absent. Sets a dummy OTLP endpoint so env-substitution of an
# unset var can't produce a false failure.
set -euo pipefail
cd "$(dirname "$0")/.."

OTELCOL_VERSION="${OTELCOL_VERSION:-0.128.0}"
OTELCOL_BIN="${OTELCOL_BIN:-/tmp/otelcol-contrib}"
CONFIG="tests/snapshots/collector/otelcol-agent.yaml.snap"

if [ ! -x "$OTELCOL_BIN" ]; then
  os="$(uname | tr '[:upper:]' '[:lower:]')"
  arch="$(uname -m)"; case "$arch" in x86_64) arch=amd64;; aarch64|arm64) arch=arm64;; esac
  url="https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v${OTELCOL_VERSION}/otelcol-contrib_${OTELCOL_VERSION}_${os}_${arch}.tar.gz"
  echo "Downloading otelcol-contrib ${OTELCOL_VERSION} ($os/$arch)..."
  tmp="$(mktemp -d)"
  curl -fsSL "$url" -o "$tmp/oc.tar.gz"
  tar -xzf "$tmp/oc.tar.gz" -C "$tmp" otelcol-contrib
  mv "$tmp/otelcol-contrib" "$OTELCOL_BIN"; chmod +x "$OTELCOL_BIN"; rm -rf "$tmp"
fi

# Dummy endpoint just so ${env:...} resolves to a non-empty value during validate.
OTEL_EXPORTER_OTLP_ENDPOINT="localhost:4317" "$OTELCOL_BIN" validate --config="$CONFIG"
echo "OK: $CONFIG validates against otelcol-contrib ${OTELCOL_VERSION}"
