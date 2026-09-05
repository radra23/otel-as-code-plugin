#!/usr/bin/env bash
# tests/hooks/go-scanner-gate.test.sh
# Locks the Go generatorSupported gate added to agents/repo-context-scanner.md (#115): net/http
# server evidence required, gin/echo/fiber refused with a named reason, inScope stays true
# regardless of generatorSupported. Ties the RULE in the scanner prompt to the FIXTURE that
# exercises it (the freshness-contract / dogfooding-regression pattern) — a later edit to either
# half alone is caught.
set -uo pipefail
cd "$(dirname "$0")/../.."
pass=0; fail=0
check() { if eval "$2"; then echo "PASS: $1"; pass=$((pass+1)); else echo "FAIL: $1"; fail=$((fail+1)); fi; }

SCANNER="agents/repo-context-scanner.md"
NETHTTP="fixtures/go-greenfield"
GIN="fixtures/go-gin-app"
CLI="fixtures/go-cli"
CHI="fixtures/go-chi-app"
ECHO="fixtures/go-echo-app"

# --- positive: net/http server evidence -> generatorSupported:true ---
check "scanner names http.ListenAndServe as net/http evidence" \
  'grep -q "http.ListenAndServe" "$SCANNER"'
check "go-greenfield fixture has that exact evidence (repro intact)" \
  'grep -q "http.ListenAndServe" "$NETHTTP/main.go"'
check "go-greenfield fixture requires no incompatible framework" \
  '! grep -qE "gin-gonic/gin|labstack/echo|gofiber/fiber" "$NETHTTP/go.mod"'

# --- negative: gin -> generatorSupported:false, reason names gin ---
check "scanner names gin as an unsupported framework" \
  'grep -q "gin-gonic/gin" "$SCANNER"'
check "go-gin-app fixture requires gin (repro intact)" \
  'grep -q "gin-gonic/gin" "$GIN/go.mod"'
check "go-gin-app fixture has NO net/http server evidence (gin has its own)" \
  '! grep -qE "http.ListenAndServe|http.ListenAndServeTLS|http.Handle" "$GIN/main.go"'

# --- positive: chi/gorilla-mux are net/http-compatible -> covered for free ---
check "scanner names chi and gorilla/mux as covered for free" \
  'grep -q "chi" "$SCANNER" && grep -q "gorilla/mux" "$SCANNER"'
check "go-chi-app fixture requires chi (repro intact)" \
  'grep -q "go-chi/chi" "$CHI/go.mod"'
check "go-chi-app fixture has net/http server evidence despite using chi" \
  'grep -q "http.ListenAndServe" "$CHI/main.go"'

# --- negative: echo -> generatorSupported:false, reason names echo (proves the OR-clause
#     generalizes past gin, not a gin-only special case) ---
check "scanner names echo as an unsupported framework" \
  'grep -q "labstack/echo" "$SCANNER"'
check "go-echo-app fixture requires echo (repro intact)" \
  'grep -q "labstack/echo" "$ECHO/go.mod"'
check "go-echo-app fixture has NO net/http server evidence (echo has its own Start method)" \
  '! grep -qE "http.ListenAndServe|http.ListenAndServeTLS|http.Handle" "$ECHO/main.go"'

# --- negative: no HTTP server at all -> generatorSupported:false, inScope stays true ---
check "scanner states go stays inScope:true regardless of generatorSupported" \
  'grep -q "first-class OTel runtime" "$SCANNER"'
check "go-cli fixture has NO net/http server evidence (the disqualifying fact)" \
  '! grep -qE "http.ListenAndServe|http.ListenAndServeTLS|http.Handle" "$CLI/main.go"'

echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
