#!/usr/bin/env bash
# tests/hooks/write-guard.test.sh
# Tests for the write-guard PreToolUse hook.
# Usage: bash tests/hooks/write-guard.test.sh
set -euo pipefail

HOOK="hooks/write-guard.sh"
PASS=0
FAIL=0

run_test() {
  local name="$1"; local input="$2"; local expect_exit="$3"
  actual_exit=0
  echo "$input" | bash "$HOOK" > /dev/null 2>&1 || actual_exit=$?
  if [ "$actual_exit" -eq "$expect_exit" ]; then
    echo "PASS: $name"
    PASS=$((PASS+1))
  else
    echo "FAIL: $name (expected exit $expect_exit, got $actual_exit)"
    FAIL=$((FAIL+1))
  fi
}

# Test 1: Write to a non-OTel file → allow (exit 0)
run_test "allow non-otel file" \
  '{"tool_name":"Write","tool_input":{"file_path":"src/utils.js"}}' 0

# Test 2: Write to tracing.js when it exists → block (exit 1)
TMP=$(mktemp -d)
echo "existing content" > "$TMP/tracing.js"
INPUT="{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$TMP/tracing.js\"}}"
actual_exit=0
echo "$INPUT" | bash "$HOOK" > /dev/null 2>&1 || actual_exit=$?
if [ "$actual_exit" -eq 1 ]; then
  echo "PASS: block existing tracing.js"
  PASS=$((PASS+1))
else
  echo "FAIL: block existing tracing.js (expected 1, got $actual_exit)"
  FAIL=$((FAIL+1))
fi
rm -rf "$TMP"

# Test 3: Write to infra/observability/datadog/main.tf when it exists → block (exit 1)
TMP=$(mktemp -d)
mkdir -p "$TMP/infra/observability/datadog"
echo "existing tf" > "$TMP/infra/observability/datadog/main.tf"
INPUT="{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$TMP/infra/observability/datadog/main.tf\"}}"
actual_exit=0
echo "$INPUT" | bash "$HOOK" > /dev/null 2>&1 || actual_exit=$?
if [ "$actual_exit" -eq 1 ]; then
  echo "PASS: block existing terraform file"
  PASS=$((PASS+1))
else
  echo "FAIL: block existing terraform file (expected 1, got $actual_exit)"
  FAIL=$((FAIL+1))
fi
rm -rf "$TMP"

# Test 4: OTEL_FORCE=1 env override → allow (exit 0)
TMP=$(mktemp -d)
echo "existing content" > "$TMP/tracing.js"
INPUT="{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$TMP/tracing.js\"}}"
actual_exit=0
echo "$INPUT" | OTEL_FORCE=1 bash "$HOOK" > /dev/null 2>&1 || actual_exit=$?
if [ "$actual_exit" -eq 0 ]; then
  echo "PASS: OTEL_FORCE env override allows overwrite"
  PASS=$((PASS+1))
else
  echo "FAIL: OTEL_FORCE env override (expected 0, got $actual_exit)"
  FAIL=$((FAIL+1))
fi
rm -rf "$TMP"

# Test 5: .claude/.otel-force sentinel lists this path → allow (exit 0)
TMP=$(mktemp -d)
echo "existing content" > "$TMP/tracing.js"
mkdir -p "$TMP/.claude"
echo "$TMP/tracing.js" > "$TMP/.claude/.otel-force"
INPUT="{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$TMP/tracing.js\"}}"
actual_exit=0
echo "$INPUT" | CLAUDE_PROJECT_DIR="$TMP" bash "$HOOK" > /dev/null 2>&1 || actual_exit=$?
if [ "$actual_exit" -eq 0 ]; then
  echo "PASS: --force sentinel allows the listed path"
  PASS=$((PASS+1))
else
  echo "FAIL: --force sentinel (expected 0, got $actual_exit)"
  FAIL=$((FAIL+1))
fi
rm -rf "$TMP"

# Test 6: sentinel exists but does NOT list this path → still block (exit 1)
# Proves --force is path-scoped and never blanket-disables the guard.
TMP=$(mktemp -d)
echo "existing content" > "$TMP/tracing.js"
mkdir -p "$TMP/.claude"
echo "$TMP/unrelated.js" > "$TMP/.claude/.otel-force"
INPUT="{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$TMP/tracing.js\"}}"
actual_exit=0
echo "$INPUT" | CLAUDE_PROJECT_DIR="$TMP" bash "$HOOK" > /dev/null 2>&1 || actual_exit=$?
if [ "$actual_exit" -eq 1 ]; then
  echo "PASS: --force sentinel does not blanket-disable the guard"
  PASS=$((PASS+1))
else
  echo "FAIL: --force path-scoping (expected 1, got $actual_exit)"
  FAIL=$((FAIL+1))
fi
rm -rf "$TMP"

# Test 7: writing otel-context.json with an UNCONFIRMED business attr → block (exit 1)
TMP=$(mktemp -d); mkdir -p "$TMP/.claude"
CTX='{"schemaVersion":"1","businessAttrs":[{"name":"biz.checkout.conversion_rate","confirmed":false}]}'
INPUT=$(python3 -c "import json,sys; print(json.dumps({'tool_name':'Write','tool_input':{'file_path':sys.argv[1],'content':sys.argv[2]}}))" "$TMP/.claude/otel-context.json" "$CTX")
actual_exit=0
echo "$INPUT" | bash "$HOOK" > /dev/null 2>&1 || actual_exit=$?
if [ "$actual_exit" -eq 1 ]; then
  echo "PASS: blocks unconfirmed business attribute write"
  PASS=$((PASS+1))
else
  echo "FAIL: unconfirmed business attr (expected 1, got $actual_exit)"
  FAIL=$((FAIL+1))
fi
rm -rf "$TMP"

# Test 8: writing otel-context.json with ALL business attrs confirmed → allow (exit 0)
TMP=$(mktemp -d); mkdir -p "$TMP/.claude"
CTX='{"schemaVersion":"1","businessAttrs":[{"name":"biz.checkout.conversion_rate","confirmed":true}]}'
INPUT=$(python3 -c "import json,sys; print(json.dumps({'tool_name':'Write','tool_input':{'file_path':sys.argv[1],'content':sys.argv[2]}}))" "$TMP/.claude/otel-context.json" "$CTX")
actual_exit=0
echo "$INPUT" | bash "$HOOK" > /dev/null 2>&1 || actual_exit=$?
if [ "$actual_exit" -eq 0 ]; then
  echo "PASS: allows fully-confirmed business attrs"
  PASS=$((PASS+1))
else
  echo "FAIL: confirmed business attrs (expected 0, got $actual_exit)"
  FAIL=$((FAIL+1))
fi
rm -rf "$TMP"

# Test 9: Write to otel-java.env (the generated Java agent config) when it exists → block (exit 1)
TMP=$(mktemp -d)
echo "OTEL_SERVICE_NAME=checkout-api" > "$TMP/otel-java.env"
INPUT="{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$TMP/otel-java.env\"}}"
actual_exit=0
echo "$INPUT" | bash "$HOOK" > /dev/null 2>&1 || actual_exit=$?
if [ "$actual_exit" -eq 1 ]; then
  echo "PASS: block existing otel-java.env"
  PASS=$((PASS+1))
else
  echo "FAIL: block existing otel-java.env (expected 1, got $actual_exit)"
  FAIL=$((FAIL+1))
fi
rm -rf "$TMP"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
