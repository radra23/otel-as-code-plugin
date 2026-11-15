#!/usr/bin/env bash
# tests/e2e/assert-lgtm.test.sh: offline test of assert-lgtm.sh and scripts/lgtm_check.py.
set -uo pipefail
cd "$(dirname "$0")"
pass=0; fail=0
check() { if eval "$2"; then echo "PASS: $1"; pass=$((pass+1)); else echo "FAIL: $1"; fail=$((fail+1)); fi; }
CHECK=../../scripts/lgtm_check.py

check "trace for the service passes" \
  'bash assert-lgtm.sh --search-json fixtures/tempo-search-ok.json --service checkout-api >/dev/null'
check "empty search fails" \
  '! bash assert-lgtm.sh --search-json fixtures/tempo-search-empty.json --service checkout-api >/dev/null'
check "a trace from another service does not count" \
  '! bash assert-lgtm.sh --search-json fixtures/tempo-search-other-service.json --service checkout-api >/dev/null'
check "a response with no traces key fails rather than crashing" \
  'bash assert-lgtm.sh --search-json fixtures/tempo-search-no-traces-key.json --service checkout-api >/dev/null; [ $? -eq 1 ]'
check "output says what was checked" \
  'bash assert-lgtm.sh --search-json fixtures/tempo-search-ok.json --service checkout-api | grep -q "^checked: .*service.name=checkout-api"'

# The live query: datasource-proxy route, TraceQL on resource.service.name, explicit start/end.
url=$(python3 -c "import sys; sys.path.insert(0, '../../scripts'); import lgtm_check as m; print(m.search_url('http://localhost:3001/', 'checkout-api', 100, 200))")
check "query goes through Grafana's tempo datasource proxy" \
  'case "$url" in http://localhost:3001/api/datasources/proxy/uid/tempo/api/search\?*) true;; *) false;; esac'
check "query carries explicit start and end" \
  'case "$url" in *start=100*end=200*) true;; *) false;; esac'
check "query filters on resource.service.name" \
  'python3 -c "import sys,urllib.parse as u; q=u.parse_qs(u.urlsplit(sys.argv[1]).query)[\"q\"][0]; sys.exit(q != \"{resource.service.name=\\\"checkout-api\\\"}\")" "$url"'

# Nothing listening: Grafana unreachable is exit 2 and says so, never "no traces".
free_port=$(python3 -c "import socket; s=socket.socket(); s.bind(('127.0.0.1',0)); print(s.getsockname()[1]); s.close()")
out=$(python3 $CHECK traces --grafana "http://127.0.0.1:$free_port" --service checkout-api 2>&1); rc=$?
check "unreachable Grafana exits 2" '[ "$rc" -eq 2 ]'
check "unreachable Grafana is reported as unreachable" 'printf "%s" "$out" | grep -q "^unreachable:"'

# ports: a held port is reported as taken, by number, with exit 3.
held=$(mktemp); python3 -c "
import socket,sys,time
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(('127.0.0.1',0)); s.listen(1)
open(sys.argv[1],'w').write(str(s.getsockname()[1])); sys.stdout.flush(); time.sleep(20)" "$held" & holder=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$held" ] && break; sleep 0.2; done
hp=$(cat "$held")
out=$(python3 $CHECK ports --grafana-port "$hp"); rc=$?
{ kill "$holder"; wait "$holder"; } 2>/dev/null; rm -f "$held"
check "a held Grafana port exits 3" '[ "$rc" -eq 3 ]'
check "the held port is named" 'printf "%s" "$out" | grep -q "^taken: $hp (Grafana)"'

# span: a real Tempo response, saved from the local stack (an Express checkout with nested
# manual spans), read for one span and its parent.
NEST=fixtures/tempo-trace-nested.json
check "span: a nested span is found with its parent's name (base64 span ids decoded)" \
  'python3 $CHECK span --trace-json $NEST --name db.getProduct | grep -q "nested under \"inventory.loadLines\""'
check "span: --parent passes when the parent matches" \
  'python3 $CHECK span --trace-json $NEST --name db.getProduct --parent inventory.loadLines >/dev/null'
python3 $CHECK span --trace-json $NEST --name db.getProduct --parent "POST /checkout" >/dev/null; rc=$?
check "span: --parent fails with exit 1 when the parent is another span" '[ "$rc" -eq 1 ]'
check "span: the root span is reported as having no parent" \
  'python3 $CHECK span --trace-json $NEST --name "POST /checkout" | grep -q "a root span"'
python3 $CHECK span --trace-json $NEST --name no.such.span >/dev/null; rc=$?
check "span: a span that is not in the trace exits 1" '[ "$rc" -eq 1 ]'
python3 $CHECK span --trace-json $NEST --name db.getProduct --status error >/dev/null; rc=$?
check "span: --status error does not accept a span without an error" '[ "$rc" -eq 1 ]'
errtrace=$(mktemp)
echo '{"batches":[{"scopeSpans":[{"spans":[{"spanId":"aaaaaaaaaaaaaaaa","name":"orders.checkout","startTimeUnixNano":"0","endTimeUnixNano":"5000000","status":{"code":"STATUS_CODE_ERROR"}}]}]}]}' > "$errtrace"
check "span: --status error accepts a span that recorded one, and says so" \
  'python3 $CHECK span --trace-json "$errtrace" --name orders.checkout --status error | grep -q "recorded an error"'
rm -f "$errtrace"
surl=$(python3 -c "import sys; sys.path.insert(0, '../../scripts'); import lgtm_check as m; print(m.span_search_url('http://localhost:3001', 'svc', 'orders.checkout', 100, 200, 'error'))")
check "span: the live query uses the tempo proxy, explicit start and end, and the span name" \
  'case "$surl" in http://localhost:3001/api/datasources/proxy/uid/tempo/api/search\?*start=100*end=200*) true;; *) false;; esac \
   && python3 -c "import sys,urllib.parse as u; q=u.parse_qs(u.urlsplit(sys.argv[1]).query)[\"q\"][0]; sys.exit(q != \"{resource.service.name=\\\"svc\\\" && name=\\\"orders.checkout\\\" && status=error}\")" "$surl"'
out=$(python3 $CHECK span --grafana "http://127.0.0.1:$free_port" --service svc --name x 2>&1); rc=$?
check "span: an unreachable Grafana exits 2 and says unreachable" '[ "$rc" -eq 2 ] && printf "%s" "$out" | grep -q "^unreachable:"'

echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
