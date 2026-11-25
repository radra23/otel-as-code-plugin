#!/usr/bin/env bash
# tests/e2e/log-trace-ids.sh
# Trace IDs in log lines (#279): a line logged while a request is handled carries the trace ID
# of that request's span, and the application's own logging setup is left as it was.
#   - Python: fixtures/python-greenfield (FastAPI + the standard `logging` module) behind the
#     golden tracing.py, with five logging setups an app might have (tests/log-trace-ids/main.py).
#     The plain formatter gets the IDs appended after the app's own format; a JSON formatter gets
#     them as fields; a custom formatter class, hand-made JSON and a format that already shows the
#     ID are not touched. The --experimental golden is run once to prove it carries the same block.
#   - Node.js: express + pino, winston and bunyan behind the golden tracing.js. The bundle's
#     instrumentations already add the IDs; this pins it. console.log gets nothing, which is said
#     in the docs and held here so it stays true.
#   - Java: the pinned agent fills the Logback and Log4j MDC, and nothing is generated into the
#     app's logging setup. A Logback and a Log4j 2 pattern with the token /otel-instrument prints
#     (read out of the generator) carry the request's trace ID; the same patterns without it, and
#     java.util.logging, are untouched. Spring Boot on its default logging gets the IDs from the
#     printed logging.pattern.level property (tests/log-trace-ids/java, java-spring).
#   - .NET: ASP.NET Core behind the golden OpenTelemetry.cs. The host already puts the request's
#     IDs in every ILogger scope; the printed appsettings.json fragment makes the console logger
#     show them (simple formatter, and the app's own json formatter kept). Exported to a local
#     OTLP/gRPC sink, since the golden has no console exporter (tests/log-trace-ids/dotnet).
#   - Go: log/slog sees a span only through the record's context. The golden tracing.go's
#     WithTraceIDs, installed by the line /otel-instrument prints, wraps the app's own text or JSON
#     handler; a record logged with the request's context carries the exported span's trace ID,
#     one logged without it is untouched (tests/log-trace-ids/go). Needs Go 1.26.
#   - Ruby: the golden tracing.rb's OtelAsCode module, used by the two lines /otel-instrument
#     prints: add_trace_ids around a Sinatra app's own stdlib Logger (plain and default formats
#     get the IDs, JSON is left alone), and a config.log_tags lambda for Rails' tagged logger.
#     Exported over OTLP/HTTP to otlp-http-sink.py (tests/log-trace-ids/ruby). Needs Ruby 3.4+.
# The span's trace ID is read from the exporter's output, the log line from the app's output, and
# the two must be equal: a trace ID that is merely present would not prove the link. No Docker.
# Needs Node 18+, Python 3.9+ with venv, JDK 17+ and Maven, the .NET 10 SDK, and network for npm,
# pip, Maven and NuGet.
set -euo pipefail
cd "$(dirname "$0")/../.."
SRC=$PWD
WORK=$(mktemp -d)
APP_PID=""
stop() { [ -n "$APP_PID" ] && { kill "$APP_PID" 2>/dev/null || true; wait "$APP_PID" 2>/dev/null || true; }; APP_PID=""; }
trap 'stop; rm -rf "$WORK"' EXIT
failed=0
ok() { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; failed=1; }
wait_up() { for _ in $(seq 1 60); do curl -fsS "$1" >/dev/null 2>&1 && return 0; sleep 0.5; done; return 1; }

# ---------------------------------------------------------------- Python
mkdir -p "$WORK/py"
cp "$SRC/fixtures/python-greenfield/app.py" "$SRC/tests/log-trace-ids/main.py" \
   "$SRC/tests/snapshots/instrument/python/requirements.txt" "$WORK/py/"
cd "$WORK/py"
python3 -m venv "$WORK/venv"
"$WORK/venv/bin/pip" install -q --disable-pip-version-check -r requirements.txt python-json-logger

# py_request <mode> [VAR=value ...]: run the service with that logging setup, reserve stock once,
# stop it. Spans land in <mode>.spans (stdout), log lines in <mode>.logs (stderr).
py_request() {
  local mode="$1"; shift
  env LOG_MODE="$mode" OTEL_TRACES_EXPORTER=console OTEL_METRICS_EXPORTER=none "$@" \
    "$WORK/venv/bin/uvicorn" main:app --port 8930 --no-access-log > "$mode.spans" 2> "$mode.logs" & APP_PID=$!
  wait_up http://localhost:8930/health || { bad "python ($mode): the service did not start"; cat "$mode.logs"; }
  curl -fsS -o /dev/null -X POST -H 'Content-Type: application/json' \
    -d '{"sku":"A-1","quantity":2,"warehouse":"us-east-1"}' http://localhost:8930/inventory/reserve
  stop
}
# The trace ID of the request's server span, from the console exporter's JSON.
py_trace_id() {
  python3 - "$1" <<'PY'
import json, re, sys
text = open(sys.argv[1], encoding="utf-8").read()
decoder = json.JSONDecoder()
ids = set()
for m in re.finditer(r"(?m)^\{$", text):
    try:
        span, _ = decoder.raw_decode(text, m.start())
    except json.JSONDecodeError:
        continue
    if span.get("kind") == "SpanKind.SERVER" and "/inventory/reserve" in span.get("name", ""):
        ids.add(span["context"]["trace_id"].removeprefix("0x"))
print(ids.pop() if len(ids) == 1 else f"expected one server span, found {len(ids)}")
PY
}
line_of() { grep -F "reserved sku=A-1" "$1" | head -1; }

cp "$SRC/tests/snapshots/instrument/python/tracing.py" tracing.py

py_request plain
tid=$(py_trace_id plain.spans); line=$(line_of plain.logs)
[[ "$tid" =~ ^[0-9a-f]{32}$ ]] && ok "python: the request made one server span" || { bad "python: $tid"; tail -20 plain.spans; }
[[ "$line" == "APP INFO inventory | reserved sku=A-1 qty=2 warehouse=us-east-1 trace_id=$tid span_id="* ]] \
  && ok "python (plain): the app's own format is kept and the line ends with the request's trace ID" \
  || { bad "python (plain): unexpected line"; echo "  line:  $line"; echo "  trace: $tid"; }
[[ "$line" =~ span_id=[0-9a-f]{16}$ ]] && ok "python (plain): the span ID follows, 16 hex digits" || bad "python (plain): no span ID at the end: $line"
grep -F "Application startup complete" plain.logs | grep -q "trace_id=" \
  && bad "python (plain): a line logged outside any request got a trace ID" \
  || ok "python (plain): a line logged outside a request is left as it was"

py_request json
tid=$(py_trace_id json.spans); line=$(line_of json.logs)
got=$(printf '%s' "$line" | python3 -c 'import json,sys; r=json.loads(sys.stdin.read()); print(r.get("otelTraceID"), len(r.get("otelSpanID","")))' 2>&1)
[ "$got" = "$tid 16" ] && ok "python (json): the line is still valid JSON and carries the trace ID as a field" \
  || { bad "python (json): got '$got', expected '$tid 16'"; echo "  $line"; }

py_request custom
tid=$(py_trace_id custom.spans); line=$(line_of custom.logs)
[ "$line" = '{"line": "INFO reserved sku=A-1 qty=2 warehouse=us-east-1"}' ] \
  && ok "python (custom formatter class): the line is exactly what the app's formatter wrote" \
  || { bad "python (custom): the line was changed"; echo "  $line"; }

py_request handmade-json
line=$(line_of handmade-json.logs)
[ "$line" = '{"level": "INFO", "msg": "reserved sku=A-1 qty=2 warehouse=us-east-1"}' ] \
  && ok "python (JSON from a format string): nothing is appended after the closing brace" \
  || { bad "python (handmade-json): the line was changed"; echo "  $line"; }

py_request own-ids
tid=$(py_trace_id own-ids.spans); line=$(line_of own-ids.logs)
[ "$line" = "INFO [$tid] reserved sku=A-1 qty=2 warehouse=us-east-1" ] \
  && ok "python (format already shows the ID): the field is filled in and nothing is added twice" \
  || { bad "python (own-ids): unexpected line"; echo "  $line"; echo "  trace: $tid"; }

py_request plain OTEL_AS_CODE_LOG_TRACE_IDS=off
line=$(line_of plain.logs)
[ "$line" = "APP INFO inventory | reserved sku=A-1 qty=2 warehouse=us-east-1" ] \
  && ok "python: OTEL_AS_CODE_LOG_TRACE_IDS=off leaves the line alone" || { bad "python (off): $line"; }

py_request plain OTEL_TRACES_EXPORTER=none
line=$(line_of plain.logs)
[ "$line" = "APP INFO inventory | reserved sku=A-1 qty=2 warehouse=us-east-1" ] \
  && ok "python: with traces off there is no span, so nothing is appended" || { bad "python (traces off): $line"; }

cp "$SRC/tests/snapshots/instrument/python/tracing.experimental.py" tracing.py
py_request plain OTEL_LOGS_EXPORTER=none
tid=$(py_trace_id plain.spans); line=$(line_of plain.logs)
[[ "$tid" =~ ^[0-9a-f]{32}$ && "$line" == *" trace_id=$tid span_id="* ]] \
  && ok "python (--experimental bootstrap): the same line carries the request's trace ID" \
  || { bad "python (--experimental): unexpected line"; echo "  line:  $line"; echo "  trace: $tid"; }

# ---------------------------------------------------------------- Node.js
mkdir -p "$WORK/node"
cp "$SRC/tests/log-trace-ids/node-app.js" "$WORK/node/app.js"
cp "$SRC/tests/snapshots/instrument/nodejs/tracing.js" "$SRC/tests/snapshots/instrument/nodejs/package.json" "$WORK/node/"
cd "$WORK/node"
npm install --no-audit --no-fund --silent
npm install --no-audit --no-fund --silent --no-save express pino winston bunyan
node_request() {   # node_request <out> [VAR=value ...]
  local out="$1"; shift
  env PORT=3920 OTEL_TRACES_EXPORTER=console OTEL_METRICS_EXPORTER=none "$@" node --require ./tracing.js app.js > "$out" 2>&1 & APP_PID=$!
  wait_up http://localhost:3920/health || { bad "node: the service did not start"; cat "$out"; }
  curl -fsS -o /dev/null http://localhost:3920/orders/7
  sleep 1; stop
}
# field <out> <text in the line> <json field>
field() { grep -F "$2" "$1" | head -1 | python3 -c 'import json,sys; print(json.loads(sys.stdin.read()).get(sys.argv[1], "absent"))' "$3" 2>/dev/null || echo "not-json"; }

node_request on.log
# The console exporter prints each span as a JavaScript object; the /orders request's server span
# is the one whose http.route is /orders/:id.
ntid=$(python3 - on.log <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
ids = {m.group(1) for block in re.split(r"(?m)^\{$", text) if "/orders/:id" in block
       for m in [re.search(r"traceId: '([0-9a-f]{32})'", block)] if m}
print(ids.pop() if len(ids) == 1 else f"expected one trace for /orders/:id, found {len(ids)}")
PY
)
[[ "$ntid" =~ ^[0-9a-f]{32}$ ]] && ok "node: the request made one trace" || { bad "node: $ntid"; tail -40 on.log; }
for lib in pino winston bunyan; do
  [ "$(field on.log "$lib order line" trace_id)" = "$ntid" ] \
    && ok "node ($lib): the line carries the request's trace ID" \
    || { bad "node ($lib): trace_id is '$(field on.log "$lib order line" trace_id)', expected '$ntid'"; grep -F "$lib order line" on.log; }
  [[ "$(field on.log "$lib order line" span_id)" =~ ^[0-9a-f]{16}$ ]] \
    && ok "node ($lib): and a span ID" || bad "node ($lib): no span_id"
done
[ "$(grep -Fx 'console order line' on.log | wc -l | tr -d ' ')" = 1 ] \
  && ok "node: console.log is not covered and its line is untouched (documented)" \
  || { bad "node: the console.log line changed"; grep -F 'console order line' on.log; }

node_request off.log OTEL_TRACES_EXPORTER=none
[ "$(field off.log "pino order line" trace_id)" = absent ] \
  && ok "node: with traces off the lines carry no trace ID (documented)" \
  || bad "node: a trace ID appeared with traces off: $(grep -F 'pino order line' off.log)"

# ---------------------------------------------------------------- Java
# The agent fills the Logback and Log4j MDC; a line shows the IDs once its pattern names them.
# The pattern token and the Spring Boot property are read out of the generator, so the lines
# proven here are the ones /otel-instrument prints. The app's own configs are written below.
GEN="$SRC/agents/instrumentation-gen.md"
gen_line() { local v; v=$(sed -n "s/^$1//p" "$GEN"); [ -n "$v" ] && [ "$(printf '%s\n' "$v" | wc -l | tr -d ' ')" = 1 ] && printf '%s' "$v"; }
TOKEN=$(gen_line 'Logback or Log4j 2 pattern, before %n: ') || bad "java: the generator has no single pattern-token line"
SPRING_PROP=$(gen_line 'Spring Boot application.properties: ') || bad "java: the generator has no single Spring Boot property line"
AGENT_VERSION=$(sed -n 's/^OTEL_JAVA_AGENT_VERSION = //p' "$GEN")
mkdir -p "$WORK/java"
cp -R "$SRC/tests/log-trace-ids/java" "$WORK/java/app"
cp -R "$SRC/tests/log-trace-ids/java-spring" "$WORK/java/spring"
cd "$WORK/java"
curl -fsSLo agent.jar \
  "https://github.com/open-telemetry/opentelemetry-java-instrumentation/releases/download/v${AGENT_VERSION}/opentelemetry-javaagent.jar"
(cd app && mvn -q -B package dependency:copy-dependencies -DskipTests)
(cd spring && mvn -q -B package -DskipTests)

OWN='APP %level %logger | %msg'
logback_cfg() { cat > "$1" <<XML
<configuration>
  <appender name="OUT" class="ch.qos.logback.core.ConsoleAppender">
    <encoder><pattern>$2%n</pattern></encoder>
  </appender>
  <root level="INFO"><appender-ref ref="OUT"/></root>
</configuration>
XML
}
log4j2_cfg() { cat > "$1" <<XML
<Configuration status="WARN">
  <Appenders><Console name="OUT" target="SYSTEM_OUT"><PatternLayout pattern="$2%n"/></Console></Appenders>
  <Loggers><Root level="info"><AppenderRef ref="OUT"/></Root></Loggers>
</Configuration>
XML
}
logback_cfg logback-own.xml "$OWN"; logback_cfg logback-ids.xml "$OWN $TOKEN"
log4j2_cfg log4j2-own.xml "$OWN"; log4j2_cfg log4j2-ids.xml "$OWN $TOKEN"

AGENT_ENV=(OTEL_SERVICE_NAME=payments-api OTEL_TRACES_EXPORTER=console OTEL_METRICS_EXPORTER=none OTEL_LOGS_EXPORTER=none)
java_request() {   # java_request <out> <logback.xml> <log4j2.xml> [VAR=value ...]
  local out="$1" lb="$2" l4="$3"; shift 3
  env PORT=8940 "${AGENT_ENV[@]}" "$@" java -javaagent:agent.jar \
    -Dlogback.configurationFile="$lb" -Dlog4j2.configurationFile="$l4" \
    -cp "app/target/classes:app/target/dependency/*" App > "$out" 2>&1 & APP_PID=$!
  wait_up http://localhost:8940/health || { bad "java: the service did not start"; tail -40 "$out"; }
  curl -fsS -o /dev/null -X POST http://localhost:8940/pay
  sleep 2; stop
}
# span_trace <out> <span name>: the trace ID of that server span, from the console exporter.
span_trace() {
  local ids; ids=$(sed -n "s#.*'$2' : \([0-9a-f]\{32\}\) [0-9a-f]\{16\} SERVER .*#\1#p" "$1" | sort -u)
  [ "$(printf '%s\n' "$ids" | grep -c . || true)" = 1 ] && echo "$ids" || echo "expected one '$2' server span, found: [$ids]"
}
jline() { { grep -F "$2" "$1" || true; } | head -1; }   # the first line with that text, or none

java_request ids.log logback-ids.xml log4j2-ids.xml
jtid=$(span_trace ids.log "POST /pay")
[[ "$jtid" =~ ^[0-9a-f]{32}$ ]] && ok "java: the request made one server span" || { bad "java: $jtid"; tail -40 ids.log; }
for lib in logback log4j2; do
  line=$(jline ids.log "$lib pay line")
  [[ "$line" =~ ^"APP INFO payments | $lib pay line orderId=o1 trace_id=$jtid span_id="[0-9a-f]{16}$ ]] \
    && ok "java ($lib): with the printed token the line carries the request's trace ID" \
    || { bad "java ($lib): unexpected line"; echo "  line:  $line"; echo "  trace: $jtid"; }
done
line=$(jline ids.log "jul pay line")
[[ -n "$line" && "$line" != *"$jtid"* ]] \
  && ok "java: java.util.logging is not covered and its line carries no ID (documented)" \
  || { bad "java (jul): '$line'"; }

java_request own.log logback-own.xml log4j2-own.xml
for lib in logback log4j2; do
  line=$(jline own.log "$lib pay line")
  [ "$line" = "APP INFO payments | $lib pay line orderId=o1" ] \
    && ok "java ($lib): the app's own pattern is left as it was" || { bad "java ($lib, own pattern): '$line'"; }
done

# Unlike Python, OTEL_TRACES_EXPORTER=none only stops the export: the agent still makes and
# samples the span, so the line carries an ID that no backend will have (measured, documented).
java_request noexport.log logback-ids.xml log4j2-ids.xml OTEL_TRACES_EXPORTER=none
line=$(jline noexport.log "logback pay line")
[[ "$line" =~ ^"APP INFO payments | logback pay line orderId=o1 trace_id="[0-9a-f]{32}" span_id="[0-9a-f]{16}$ ]] \
  && ok "java: with the traces exporter off the span still exists, so the line still has an ID (documented)" \
  || { bad "java (exporter none): '$line'"; }
java_request off.log logback-ids.xml log4j2-ids.xml OTEL_JAVAAGENT_ENABLED=false
line=$(jline off.log "logback pay line")
[ "$line" = "APP INFO payments | logback pay line orderId=o1 trace_id= span_id=" ] \
  && ok "java: with the agent off there is no span, and the token renders empty (documented)" \
  || { bad "java (agent off): '$line'"; }

spring_request() {   # spring_request <out> [extra app argument]
  local out="$1"; shift
  env "${AGENT_ENV[@]}" OTEL_SERVICE_NAME=orders java -javaagent:agent.jar -jar spring/target/app.jar \
    --server.port=8941 "$@" > "$out" 2>&1 & APP_PID=$!
  wait_up http://localhost:8941/health || { bad "java (spring): the service did not start"; tail -40 "$out"; }
  curl -fsS -o /dev/null http://localhost:8941/orders/7
  sleep 2; stop
}
spring_request spring-ids.log "--$SPRING_PROP"
stid=$(span_trace spring-ids.log "GET /orders/{id}")
line=$(jline spring-ids.log "spring order line id=7")
# trace_flags is the W3C byte: 01 is sampled; the agent's SDK also sets 02, the Level 2 "random
# trace ID" bit, so 03 is what it prints today. Only the sampled bit is required here.
[[ "$stid" =~ ^[0-9a-f]{32}$ && "$line" == *"trace_id=$stid span_id="* && "$line" =~ \ trace_flags=0[13]\ \ INFO\  ]] \
  && ok "java (spring boot): the printed property puts the request's trace ID in Boot's own line" \
  || { bad "java (spring boot): unexpected line"; echo "  line:  $line"; echo "  trace: $stid"; }
spring_request spring-own.log
line=$(jline spring-own.log "spring order line id=7")
[[ -n "$line" && "$line" != *"trace_id="* ]] \
  && ok "java (spring boot): without the property Boot's line is unchanged (documented)" \
  || { bad "java (spring boot, default): '$line'"; }

# ---------------------------------------------------------------- .NET
# The host puts the request Activity's IDs in every ILogger scope; the console logger prints
# scopes once the printed appsettings.json fragment turns them on. The fragment is read out of the
# generator. The span is the one the golden OpenTelemetry.cs exports to a local OTLP/gRPC sink,
# and its 16 raw trace-ID bytes must be in what the sink received.
FRAGMENT=$(gen_line '.NET appsettings.json, inside the top-level object: ') || bad ".NET: the generator has no single appsettings line"
mkdir -p "$WORK/dotnet"
cp "$SRC/tests/log-trace-ids/dotnet/Program.cs" "$SRC/tests/snapshots/instrument/dotnet/OpenTelemetry.cs" \
   "$SRC/tests/snapshots/instrument/dotnet/checkout-api.csproj" "$WORK/dotnet/"
cd "$WORK/dotnet"
dotnet build -nologo -v q > build.log 2>&1 || { bad ".NET: the app did not build"; tail -20 build.log; }
SINK=0
dotnet_request() {   # dotnet_request <name> <appsettings.json content> [VAR=value ...]
  local n="$1"; printf '%s\n' "$2" > bin/Debug/net10.0/appsettings.json; shift 2
  rm -rf "sink-$n"; mkdir "sink-$n"
  "$WORK/venv/bin/python" "$SRC/tests/e2e/otlp-grpc-sink.py" "sink-$n" 48417 > "sink-$n.log" 2>&1 & SINK=$!
  sleep 1
  (cd bin/Debug/net10.0 && exec env ASPNETCORE_URLS=http://127.0.0.1:8950 \
    OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:48417 "$@" dotnet checkout-api.dll) > "$n.log" 2>&1 & APP_PID=$!
  wait_up http://127.0.0.1:8950/health || { bad ".NET ($n): the service did not start"; tail -30 "$n.log"; }
  curl -fsS -o /dev/null -X POST http://127.0.0.1:8950/pay
  sleep 2; stop; sleep 1; kill "$SINK" 2>/dev/null || true; wait "$SINK" 2>/dev/null || true
}
# exported <sink dir> <trace id>: the sink received a trace export carrying that trace ID.
exported() {
  [[ "$2" =~ ^[0-9a-f]{32}$ ]] && python3 - "$1" "$2" <<'PY'
import glob, sys
tid = bytes.fromhex(sys.argv[2])
sys.exit(0 if any(tid in open(f, "rb").read() for f in glob.glob(sys.argv[1] + "/trace-*.bin")) else 1)
PY
}
scope_tid() { { grep -B1 -F "dotnet pay line" "$1" || true; } | sed -n 's/.*=> SpanId:[0-9a-f]\{16\}, TraceId:\([0-9a-f]\{32\}\),.*/\1/p' | head -1; }

dotnet_request own '{ }'
[ -n "$(grep -F 'dotnet pay line' own.log)" ] && [ -z "$(scope_tid own.log)" ] \
  && ok ".NET: the default console line carries no ID and is left as it was (documented)" \
  || { bad ".NET (default): unexpected output"; grep -B2 -F 'dotnet pay line' own.log; }

dotnet_request simple "{ $FRAGMENT }"
dtid=$(scope_tid simple.log)
exported sink-simple "$dtid" \
  && ok ".NET (simple formatter): with the printed fragment the line's scope carries the exported span's trace ID" \
  || { bad ".NET (simple): scope trace ID '$dtid' is not in any export"; grep -B2 -F 'dotnet pay line' simple.log; }

dotnet_request json "{ ${FRAGMENT/\"simple\"/\"json\"} }"
jtid=$({ grep -F '"Message":"dotnet pay line' json.log || true; } | head -1 | python3 -c '
import json, sys
try: rec = json.loads(sys.stdin.read())
except ValueError: sys.exit("not json")
print(next((s["TraceId"] for s in rec.get("Scopes", []) if isinstance(s, dict) and "TraceId" in s), ""))' 2>&1)
exported sink-json "$jtid" \
  && ok ".NET (json formatter, kept): the record's Scopes carry the exported span's trace ID" \
  || { bad ".NET (json): scope trace ID '$jtid' is not in any export"; grep -F 'dotnet pay line' json.log; }

dotnet_request noendpoint "{ $FRAGMENT }" OTEL_EXPORTER_OTLP_ENDPOINT=
ntid=$(scope_tid noendpoint.log)
[[ "$ntid" =~ ^[0-9a-f]{32}$ ]] && [ -z "$(ls sink-noendpoint)" ] \
  && ok ".NET: with no endpoint nothing is exported, yet the line still has an ID (documented)" \
  || { bad ".NET (no endpoint): id '$ntid', sink got [$(ls sink-noendpoint | tr '\n' ' ')]"; }

# ---------------------------------------------------------------- Go
# log/slog has no MDC: a record sees the span only through the context it is logged with. The
# golden tracing.go's WithTraceIDs wraps the app's own handler; the line that installs it is read
# out of the generator and put where the app sets up its logger. Spans go to the OTLP/gRPC sink.
GO_LINE=$(grep -x 'slog.SetDefault(slog.New(WithTraceIDs(slog.NewTextHandler(os.Stderr, nil))))' "$GEN" | sort -u)
[ "$(grep -cx 'slog.SetDefault(slog.New(WithTraceIDs(slog.NewTextHandler(os.Stderr, nil))))' "$GEN")" = 1 ] \
  || bad "go: the generator does not print exactly one WithTraceIDs line"
go_build() {   # go_build <dir> <log setup line>: the test app with that logging setup
  mkdir -p "$1"
  cp "$SRC/tests/snapshots/instrument/go/tracing.go" "$SRC/tests/snapshots/instrument/go/go.mod" \
     "$SRC/tests/snapshots/instrument/go/go.sum" "$1/"
  python3 - "$SRC/tests/log-trace-ids/go/main.go" "$1/main.go" "$2" <<'PY'
import sys
src, dst, line = sys.argv[1:4]
lines = open(src, encoding="utf-8").read().split("\n")
i = lines.index("\t// log setup")
lines[i + 1] = "\t" + line
open(dst, "w", encoding="utf-8").write("\n".join(lines))
PY
  (cd "$1" && go build -o app .) || bad "go: the app did not build with: $2"
}
go_request() {   # go_request <dir> [VAR=value ...]
  local d="$1"; shift
  rm -rf "$d/sink"; mkdir "$d/sink"
  "$WORK/venv/bin/python" "$SRC/tests/e2e/otlp-grpc-sink.py" "$d/sink" 48418 > "$d/sink.log" 2>&1 & SINK=$!
  sleep 1
  env PORT=8960 OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:48418 "$@" "$d/app" > "$d/out.log" 2>&1 & APP_PID=$!
  wait_up http://127.0.0.1:8960/health || { bad "go ($d): the service did not start"; tail -20 "$d/out.log"; }
  curl -fsS -o /dev/null -X POST http://127.0.0.1:8960/pay
  stop; sleep 1; kill "$SINK" 2>/dev/null || true; wait "$SINK" 2>/dev/null || true
}
gline() { { grep -F "$2" "$1/out.log" || true; } | head -1; }
cd "$WORK"
go_build go-own 'slog.SetDefault(slog.New(slog.NewTextHandler(os.Stderr, nil)))'
go_build go-ids "$GO_LINE"
go_build go-json "${GO_LINE/NewTextHandler/NewJSONHandler}"

go_request go-own
line=$(gline go-own 'msg="go pay line"')
[[ "$line" == *'msg="go pay line" orderId=o1' ]] \
  && ok "go: the app's own handler, unwrapped, writes its line as before (no ID)" || bad "go (own): '$line'"

go_request go-ids
line=$(gline go-ids 'msg="go pay line"')
gtid=$(sed -n 's/.* trace_id=\([0-9a-f]\{32\}\) span_id=[0-9a-f]\{16\}$/\1/p' <<<"$line")
[[ "$line" == *'msg="go pay line" orderId=o1 trace_id='* ]] && exported go-ids/sink "$gtid" \
  && ok "go: with the printed WithTraceIDs line the line carries the exported span's trace ID" \
  || { bad "go (WithTraceIDs): unexpected line"; echo "  line: $line"; }
line=$(gline go-ids 'msg="go pay line without context"')
[[ -n "$line" && "$line" != *trace_id=* ]] \
  && ok "go: a record logged without the request's context gets no ID (documented)" || bad "go (no context): '$line'"

go_request go-json
jline=$(gline go-json '"msg":"go pay line"')
gjtid=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("trace_id", ""))' "$jline" 2>/dev/null || true)
exported go-json/sink "$gjtid" \
  && ok "go: wrapped around the app's JSON handler, the record has the exported span's trace ID as a field" \
  || { bad "go (json): unexpected record"; echo "  record: $jline"; }

go_request go-ids OTEL_EXPORTER_OTLP_ENDPOINT=
line=$(gline go-ids 'msg="go pay line"')
[[ "$line" == *'msg="go pay line" orderId=o1' ]] \
  && ok "go: with no endpoint there is no tracer provider, so no span and no ID (documented)" \
  || bad "go (no endpoint): '$line'"

# ---------------------------------------------------------------- Ruby
# The golden tracing.rb's OtelAsCode module does the work; the two lines that use it are read out
# of the generator and put where each test app sets up its logging. The Ruby exporter speaks
# OTLP/HTTP, so spans go to otlp-http-sink.py; the trace-ID bytes must be in what it received.
rb_line() { [ "$(grep -cxF "  $1" "$GEN")" = 1 ] && printf '%s' "$1"; }
RB_LOGGER=$(rb_line 'OtelAsCode.add_trace_ids(logger)') || bad "ruby: the generator does not print the Logger line exactly once"
RB_TAGS=$(rb_line 'config.log_tags = [:request_id, ->(_req) { OtelAsCode.trace_log_tag }]') \
  || bad "ruby: the generator does not print the Rails log_tags line exactly once"
mkdir -p "$WORK/ruby/config/initializers"
cd "$WORK/ruby"
cp "$SRC/tests/log-trace-ids/ruby/Gemfile" .
cp "$SRC/tests/snapshots/instrument/ruby/tracing.rb" tracing.rb
cp "$SRC/tests/snapshots/instrument/ruby/tracing.rb" config/initializers/opentelemetry.rb
export BUNDLE_GEMFILE="$WORK/ruby/Gemfile" BUNDLE_PATH="$WORK/ruby/vendor"
bundle install --quiet || bad "ruby: bundle install failed"
rb_place() {   # rb_place <fixture> <out> <marker> <line or empty>: the app with the printed line in place
  python3 - "$SRC/tests/log-trace-ids/ruby/$1" "$2" "$3" "$4" <<'PY'
import sys
src, dst, marker, line = sys.argv[1:5]
lines = open(src, encoding="utf-8").read().split("\n")
i = [n for n, l in enumerate(lines) if l.strip() == marker][0]
indent = lines[i][: len(lines[i]) - len(lines[i].lstrip())]
if line:
    lines[i + 1] = indent + line
open(dst, "w", encoding="utf-8").write("\n".join(lines))
PY
}
rb_place app.rb app-own.rb "# log setup" ""
rb_place app.rb app-ids.rb "# log setup" "$RB_LOGGER"
rb_place rails_app.rb rails-own.rb "# log tags" ""
rb_place rails_app.rb rails-ids.rb "# log tags" "$RB_TAGS"
rb_request() {   # rb_request <name> <script> <port> <method> <path> [VAR=value ...]
  local n="$1" script="$2" port="$3" method="$4" path="$5"; shift 5
  rm -rf "sink-$n"; mkdir "sink-$n"
  python3 "$SRC/tests/e2e/otlp-http-sink.py" "sink-$n" 48419 > "sink-$n.log" 2>&1 & SINK=$!
  sleep 0.5
  env PORT="$port" OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:48419 OTEL_BSP_SCHEDULE_DELAY=200 "$@" \
    bundle exec ruby "$script" > "$n.log" 2>&1 & APP_PID=$!
  wait_up "http://127.0.0.1:$port/health" || { bad "ruby ($n): the service did not start"; tail -20 "$n.log"; }
  curl -fsS -o /dev/null -X "$method" "http://127.0.0.1:$port$path"
  sleep 1.5; stop; sleep 0.5; kill "$SINK" 2>/dev/null || true; wait "$SINK" 2>/dev/null || true
}
rline() { { grep -F "$2" "$1.log" || true; } | head -1; }
rtid() { sed -n 's/.*trace_id=\([0-9a-f]\{32\}\) span_id=[0-9a-f]\{16\}.*/\1/p' <<<"$1"; }

rb_request plain-own app-own.rb 8970 POST /pay LOG_MODE=plain
line=$(rline plain-own "ruby pay line")
[ "$line" = "APP INFO | ruby pay line orderId=o1" ] \
  && ok "ruby: the app's own Logger format, without the printed line, is left as it was" || bad "ruby (own): '$line'"
rb_request plain-ids app-ids.rb 8970 POST /pay LOG_MODE=plain
line=$(rline plain-ids "ruby pay line")
[[ "$line" =~ ^"APP INFO | ruby pay line orderId=o1 trace_id="[0-9a-f]{32}" span_id="[0-9a-f]{16}$ ]] && exported sink-plain-ids "$(rtid "$line")" \
  && ok "ruby: with OtelAsCode.add_trace_ids the app's own line ends with the exported span's trace ID" \
  || { bad "ruby (add_trace_ids): unexpected line"; echo "  line: $line"; }
rb_request default-ids app-ids.rb 8970 POST /pay
line=$(rline default-ids "ruby pay line")
[[ "$line" == *"INFO -- : ruby pay line orderId=o1 trace_id="* ]] && exported sink-default-ids "$(rtid "$line")" \
  && ok "ruby: Logger's default format gets the same IDs at the end of the line" \
  || { bad "ruby (default format): unexpected line"; echo "  line: $line"; }
rb_request json-ids app-ids.rb 8970 POST /pay LOG_MODE=json
line=$(rline json-ids "ruby pay line")
[ "$line" = '{"level":"INFO","msg":"ruby pay line orderId=o1"}' ] \
  && ok "ruby: a JSON line is left as it was, nothing appended after the brace (documented)" || bad "ruby (json): '$line'"
rb_request noendpoint-ids app-ids.rb 8970 POST /pay LOG_MODE=plain OTEL_EXPORTER_OTLP_ENDPOINT=
line=$(rline noendpoint-ids "ruby pay line")
[ "$line" = "APP INFO | ruby pay line orderId=o1" ] \
  && ok "ruby: with no endpoint there are no spans, so the line is unchanged (documented)" || bad "ruby (no endpoint): '$line'"

rb_request rails-ids rails-ids.rb 8971 GET /orders/7
line=$(rline rails-ids "rails order line id=7")
[[ "$line" =~ ^"["[0-9a-f-]{36}"] [trace_id="[0-9a-f]{32}" span_id="[0-9a-f]{16}"] rails order line id=7"$ ]] && exported sink-rails-ids "$(rtid "$line")" \
  && ok "ruby (rails): the printed log_tags line tags the request's lines with the exported span's trace ID" \
  || { bad "ruby (rails): unexpected line"; echo "  line: $line"; }
rb_request rails-own rails-own.rb 8971 GET /orders/7
line=$(rline rails-own "rails order line id=7")
[ "$line" = "rails order line id=7" ] \
  && ok "ruby (rails): without the line Rails' own output is unchanged" || bad "ruby (rails, own): '$line'"
rb_request rails-noendpoint rails-ids.rb 8971 GET /orders/7 OTEL_EXPORTER_OTLP_ENDPOINT=
line=$(rline rails-noendpoint "rails order line id=7")
[[ "$line" =~ ^"["[0-9a-f-]{36}"] rails order line id=7"$ ]] \
  && ok "ruby (rails): with no endpoint the tag is dropped, never printed as zeros (documented)" \
  || bad "ruby (rails, no endpoint): '$line'"
unset BUNDLE_GEMFILE BUNDLE_PATH

[ "$failed" -eq 0 ] && echo "LOG TRACE IDS E2E PASS: log lines carry their request's trace ID, and the app's logging setup is untouched" \
  || { echo "LOG TRACE IDS E2E FAIL"; exit 1; }
