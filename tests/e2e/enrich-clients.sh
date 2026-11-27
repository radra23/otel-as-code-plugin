#!/usr/bin/env bash
# tests/e2e/enrich-clients.sh
# Proves /otel-enrich --clients against real packages, with the rule it exists for: exactly one
# client span per database call.
#   - Python: tests/enrich/py-clients (FastAPI + the standard library's sqlite3) with the golden
#     tracing.py. Before: no client span at all. After `enrich.py client --name sqlite3` and a
#     plain `pip install -r requirements.txt`: one per query.
#   - Python: tests/enrich/py-sqlalchemy (SQLAlchemy over sqlite3): sqlite3 is left to SQLAlchemy,
#     and an unpinned SQLAlchemy past the package's range is reported as "pin" and makes no span
#     until the requirement is capped; then one per query.
#   - Python: tests/enrich/py-tortoise (Tortoise ORM over a SQLite file, async): one span per query.
#   - Python: tests/enrich/py-redis (FastAPI + a Redis cache): one span per Redis command, against a
#     real server (a CI service container; "not checked" where none answers).
#   - Python: tests/enrich/py-psycopg (FastAPI + Postgres through psycopg 3): one span per query,
#     against a real server the same way.
#   - Python: tests/enrich/py-asyncpg (the same service on asyncio through asyncpg), on the same server.
#   - Python: tests/enrich/py-aiopg (the same service on aiopg, over psycopg2), on the same server.
#   - Python: tests/enrich/py-psycopg2 (the same service on psycopg2 directly), on the same server.
#   - Python: tests/enrich/py-pymysql (the same service on MySQL through PyMySQL), against a MySQL server.
#   - Python: tests/enrich/py-mysql-connector (the same service on mysql-connector-python), on the same server.
#   - Python: tests/enrich/py-mysqlclient (the same service on mysqlclient, built against libmysqlclient).
#   - Node.js: tests/enrich/node-clients (express + node:sqlite, which no package covers) with the
#     golden tracing.js. `enrich.py span --client node:sqlite` around the function that queries:
#     one client span per call. `pg`, which the bundle covers, is refused a hand-made span.
# Spans are read from the console exporter (OTEL_TRACES_EXPORTER=console), where every span the
# process made is visible, so "exactly one" is a count and not a search. No Docker, except the
# Redis, Postgres and MySQL servers CI starts as service containers.
# Needs Node 22.13+ (node:sqlite), Python 3.9+ with venv, and network for npm and pip.
set -euo pipefail
cd "$(dirname "$0")/../.."
SRC=$PWD
WORK=$(mktemp -d)
APP_PID=""
stop() { [ -n "$APP_PID" ] && { kill "$APP_PID" 2>/dev/null || true; wait "$APP_PID" 2>/dev/null || true; }; APP_PID=""; }
trap 'stop; rm -rf "$WORK"' EXIT
enrich() { python3 "$SRC/scripts/enrich.py" "$@"; }
failed=0
ok() { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; failed=1; }
# is <name> <actual> <expected>
is() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', expected '$3')"; fi; }
status_of() { enrich clients --root . --json "${@:2}" | python3 -c '
import json, sys
rows = {r["client"]: r["status"] for r in json.load(sys.stdin)["clients"]}
print(rows.get(sys.argv[1], "absent"))' "$1"; }
wait_up() { for _ in $(seq 1 40); do curl -fsS "$1" >/dev/null 2>&1 && return 0; sleep 0.5; done; return 1; }
get() { curl -s -o /dev/null -w '%{http_code}' "$1"; }

# ---------------------------------------------------------------- Python
mkdir -p "$WORK/py"
cp "$SRC/tests/enrich/py-clients/app.py" "$SRC/tests/snapshots/instrument/python/tracing.py" \
   "$SRC/tests/snapshots/instrument/python/requirements.txt" "$WORK/py/"
cd "$WORK/py"
printf 'import tracing\nfrom app import app\ntracing.instrument_fastapi(app)\n' > main.py
cp -R "$WORK/py" "$WORK/py-before"
python3 -m venv "$WORK/venv"
"$WORK/venv/bin/pip" install -q --disable-pip-version-check -r requirements.txt
py_run() {   # py_run <log>: start the service printing its spans to <log>
  OTEL_TRACES_EXPORTER=console OTEL_METRICS_EXPORTER=none OTEL_SERVICE_NAME=enrich-catalog \
    "$WORK/venv/bin/uvicorn" main:app --port 8910 > "$1" 2>&1 & APP_PID=$!
  wait_up http://localhost:8910/health || { bad "python: the service did not start"; cat "$1"; }
}
py_clients() { grep -c '"kind": "SpanKind.CLIENT"' "$1" || true; }

is "python: sqlite3 is reported as a client whose package is not installed" "$(status_of sqlite3)" install
py_run "$WORK/before.log"; get http://localhost:8910/items/1 >/dev/null; stop
is "python: before, a query makes no client span (the gap this closes)" "$(py_clients "$WORK/before.log")" 0

enrich client --root . --name sqlite3 --bootstrap tracing.py >/dev/null
grep -q '^opentelemetry-instrumentation-sqlite3>=0.66b2$' requirements.txt \
  && ok "python: the requirement is pinned to the release the other instrumentation package uses" \
  || { bad "python: requirement line missing or unpinned"; tail -4 requirements.txt; }
"$WORK/venv/bin/pip" install -q --disable-pip-version-check -r requirements.txt
is "python: after the install, sqlite3 is reported as turned on" "$(status_of sqlite3)" enabled
out=$(enrich client --root . --name sqlite3 --bootstrap tracing.py 2>&1) && rc=0 || rc=$?
{ [ "$rc" = 2 ] && printf '%s' "$out" | grep -q "Nothing to add"; } \
  && ok "python: turning it on twice is refused" || bad "python: a second run was not refused: $out"

py_run "$WORK/after.log"
codes="$(get http://localhost:8910/items/1) $(get http://localhost:8910/items/2) $(get http://localhost:8910/items/1) $(get http://localhost:8910/items/9)"
stop
is "python: the service answers as before (three hits, one 404)" "$codes" "200 200 200 404"
is "python: four queries made exactly four client spans, one each" "$(py_clients "$WORK/after.log")" 4
grep -q '"name": "SELECT"' "$WORK/after.log" \
  && ok "python: the client spans come from the package (named after the statement)" \
  || { bad "python: no SELECT span in the output"; tail -40 "$WORK/after.log"; }
! grep -q "is not installed" "$WORK/after.log" \
  && ok "python: the bootstrap found the package" || bad "python: the bootstrap reported the package missing"

enrich remove --root . >/dev/null
rm -rf __pycache__ "$WORK/py-before/__pycache__"
diff -r "$WORK/py-before" "$WORK/py" >/dev/null \
  && ok "python: enrich.py remove restored the bootstrap and requirements.txt byte for byte" \
  || { bad "python: files differ after removal"; diff -r "$WORK/py-before" "$WORK/py" | head; }

# ---------------------------------------------------------------- Python, SQLAlchemy over sqlite3
# Two rules on a real ORM. The layering one (client-coverage.json's "layers"): the app imports
# sqlite3 too, to open the engine's connections, and sqlite3 must be left alone, since its package
# under SQLAlchemy's would make two client spans per query. And the version one (#322): the
# package instruments only the SQLAlchemy versions its package.py declares, and on a newer one it
# logs a warning and makes no spans, so an unpinned requirement is reported as "pin", never
# "enabled", until the requirement is capped.
mkdir -p "$WORK/sa"
cp "$SRC/tests/enrich/py-sqlalchemy/app.py" "$SRC/tests/snapshots/instrument/python/tracing.py" \
   "$SRC/tests/snapshots/instrument/python/requirements.txt" "$WORK/sa/"
cd "$WORK/sa"
echo 'sqlalchemy>=2.0' >> requirements.txt
printf 'import tracing\nfrom app import app\ntracing.instrument_fastapi(app)\n' > main.py
cp -R "$WORK/sa" "$WORK/sa-before"
"$WORK/venv/bin/pip" install -q --disable-pip-version-check -r requirements.txt
TOP=$(python3 -c 'import json; print([r for r in json.load(open("'"$SRC"'/scripts/client-coverage.json"))["python"]["packages"] if r["label"] == "sqlalchemy"][0]["instruments"]["sqlalchemy"].split("<")[1])')
SA=$("$WORK/venv/bin/python" -c 'import sqlalchemy; print(sqlalchemy.__version__)')
past=$(python3 -c 'import sys; a, b = (tuple(map(int, v.split(".")[:3])) for v in sys.argv[1:]); print("yes" if a >= b else "no")' "$SA" "$TOP")

is "sqlalchemy: sqlite3 under it is reported as layered, not offered a package" "$(status_of sqlite3)" layered
out=$(enrich client --root . --name sqlite3 --bootstrap tracing.py 2>&1) && rc=0 || rc=$?
{ [ "$rc" = 2 ] && printf '%s' "$out" | grep -q "two spans per query"; } \
  && ok "sqlalchemy: turning sqlite3 on under it is refused" || bad "sqlalchemy: sqlite3 was not refused: $out"
out=$(enrich span --root . --file app.py --function find_item --span-name store.find_item \
  --tracer-name enrich-catalog --client sqlalchemy 2>&1) && rc=0 || rc=$?
{ [ "$rc" = 2 ] && printf '%s' "$out" | grep -q "two client spans per call"; } \
  && ok "sqlalchemy: a hand-made span for it is refused, a package covers it" || bad "sqlalchemy: --client sqlalchemy was not refused: $out"
is "sqlalchemy: the unpinned requirement is reported as pin (SQLAlchemy $SA installed, package range ends before $TOP)" \
  "$(status_of sqlalchemy)" pin
py_run "$WORK/sa-before.log"; get http://localhost:8910/items/1 >/dev/null; stop
is "sqlalchemy: before, a query makes no client span" "$(py_clients "$WORK/sa-before.log")" 0

out=$(enrich client --root . --name sqlalchemy --bootstrap tracing.py 2>&1)
printf '%s' "$out" | grep -qF "pin \`sqlalchemy<$TOP\`." \
  && ok "sqlalchemy: turning it on prints the pin it still needs" || bad "sqlalchemy: no pin line: $out"
grep -q '^opentelemetry-instrumentation-sqlalchemy>=0.66b2$' requirements.txt \
  && ok "sqlalchemy: the requirement is pinned to the release the other instrumentation package uses" \
  || { bad "sqlalchemy: requirement line missing or unpinned"; tail -4 requirements.txt; }
"$WORK/venv/bin/pip" install -q --disable-pip-version-check -r requirements.txt
is "sqlalchemy: installed and turned on, it is still pin, not enabled" "$(status_of sqlalchemy)" pin
if [ "$past" = yes ]; then
  py_run "$WORK/sa-unpinned.log"; get http://localhost:8910/items/1 >/dev/null; stop
  is "sqlalchemy: what pin is for: on SQLAlchemy $SA the package makes no client span" "$(py_clients "$WORK/sa-unpinned.log")" 0
  grep -q "falls outside of that range" "$WORK/sa-unpinned.log" \
    && ok "sqlalchemy: the instrumentor said so only in a log line" || bad "sqlalchemy: no out-of-range warning in the log"
else
  echo "NOT CHECKED: SQLAlchemy $SA is inside the package's range, so the unpinned run proves nothing"
fi

# The user's own edit, as the pin line says: cap the requirement.
sed -i.bak "s/^sqlalchemy>=2.0\$/sqlalchemy>=2.0,<$TOP/" requirements.txt && rm requirements.txt.bak
"$WORK/venv/bin/pip" install -q --disable-pip-version-check -r requirements.txt
is "sqlalchemy: pinned, it is reported as turned on" "$(status_of sqlalchemy)" enabled
is "sqlalchemy: sqlite3 is still layered, not offered" "$(status_of sqlite3)" layered

py_run "$WORK/sa-after.log"
codes="$(get http://localhost:8910/items/1) $(get http://localhost:8910/items/2) $(get http://localhost:8910/items/1) $(get http://localhost:8910/items/9)"
stop
is "sqlalchemy: the service answers as before (three hits, one 404)" "$codes" "200 200 200 404"
# The package also makes a `connect` span each time a connection is checked out, and the start-up
# CREATE and INSERT run once: those are not a second span per query, so the count is by name.
client_names() { python3 -c '
import json, re, sys
names = [s["name"] for s in (json.loads(m) for m in re.findall(r"(?ms)^\{\n.*?^\}$", open(sys.argv[1]).read()))
         if s.get("kind") == "SpanKind.CLIENT"]
print(" ".join(f"{n}={names.count(n)}" for n in sorted(set(names))))' "$1"; }
is "sqlalchemy: four queries made exactly four SELECT spans, and nothing but connect and start-up besides" \
  "$(client_names "$WORK/sa-after.log")" "CREATE=1 INSERT=1 SELECT=4 connect=5"

enrich remove --root . >/dev/null
rm -rf __pycache__ "$WORK/sa-before/__pycache__"
sed -i.bak "s/^sqlalchemy>=2.0\$/sqlalchemy>=2.0,<$TOP/" "$WORK/sa-before/requirements.txt" && rm "$WORK/sa-before/requirements.txt.bak"
diff -r "$WORK/sa-before" "$WORK/sa" >/dev/null \
  && ok "sqlalchemy: enrich.py remove restored the bootstrap and requirements.txt (but the user's pin) byte for byte" \
  || { bad "sqlalchemy: files differ after removal"; diff -r "$WORK/sa-before" "$WORK/sa" | head; }

# ---------------------------------------------------------------- Python, Tortoise ORM over SQLite
# An async ORM over a SQLite file, so no server. Tortoise reaches sqlite3 through aiosqlite, and the
# app imports neither, so sqlite3 is not offered at all. Measured (#322): sqlite3's package on as
# well added no span (aiosqlite runs statements on the connection, which that package does not
# trace), but sqlite3 stays layered under Tortoise in client-coverage.json, the safe side.
mkdir -p "$WORK/tt"
cp "$SRC/tests/enrich/py-tortoise/app.py" "$SRC/tests/snapshots/instrument/python/tracing.py" \
   "$SRC/tests/snapshots/instrument/python/requirements.txt" "$WORK/tt/"
cd "$WORK/tt"
echo 'tortoise-orm>=1.1' >> requirements.txt
printf 'import tracing\nfrom app import app\ntracing.instrument_fastapi(app)\n' > main.py
cp -R "$WORK/tt" "$WORK/tt-before"
"$WORK/venv/bin/pip" install -q --disable-pip-version-check -r requirements.txt
TV=$("$WORK/venv/bin/python" -c 'from importlib.metadata import version; print(version("tortoise-orm"))')
is "tortoise: tortoise-orm is reported as a client whose package is not installed (tortoise-orm $TV)" "$(status_of tortoise-orm)" install
is "tortoise: sqlite3 under it is not offered (the app does not import it)" "$(status_of sqlite3)" absent
export ITEMS_DB="$WORK/tt-before.db"
py_run "$WORK/tt-before.log"; get http://localhost:8910/items/1 >/dev/null; stop
is "tortoise: before, a request makes no client span" "$(py_clients "$WORK/tt-before.log")" 0

export ITEMS_DB="$WORK/tt-after.db"
enrich client --root . --name tortoise-orm --bootstrap tracing.py >/dev/null
grep -q '^opentelemetry-instrumentation-tortoiseorm>=0.66b2$' requirements.txt \
  && ok "tortoise: the requirement is pinned to the release the other instrumentation package uses" \
  || { bad "tortoise: requirement line missing or unpinned"; tail -4 requirements.txt; }
"$WORK/venv/bin/pip" install -q --disable-pip-version-check -r requirements.txt
is "tortoise: after the install, tortoise-orm is reported as turned on" "$(status_of tortoise-orm)" enabled

py_run "$WORK/tt-after.log"
# Start-up: the schema (one CREATE) and the catalog (one INSERT, bulk_create). Then one SELECT
# per request, 9 not found.
codes="$(get http://localhost:8910/items/1) $(get http://localhost:8910/items/1) $(get http://localhost:8910/items/2) $(get http://localhost:8910/items/9)"
stop
is "tortoise: the service answers as before (three found, one 404)" "$codes" "200 200 200 404"
is "tortoise: four queries made exactly four SELECT spans, and only the start-up statements besides" \
  "$(client_names "$WORK/tt-after.log")" "CREATE=1 INSERT=1 SELECT=4"

enrich remove --root . >/dev/null
rm -rf __pycache__ "$WORK/tt-before/__pycache__"
diff -r "$WORK/tt-before" "$WORK/tt" >/dev/null \
  && ok "tortoise: enrich.py remove restored the bootstrap and requirements.txt byte for byte" \
  || { bad "tortoise: files differ after removal"; diff -r "$WORK/tt-before" "$WORK/tt" | head; }

# ---------------------------------------------------------------- Python, Redis
# A client that needs a server: CI runs one as a service container and sets
# OTEL_AS_CODE_REQUIRE_REDIS=1, so there a missing server fails; anywhere else it is "not checked".
mkdir -p "$WORK/rd"
cp "$SRC/tests/enrich/py-redis/app.py" "$SRC/tests/snapshots/instrument/python/tracing.py" \
   "$SRC/tests/snapshots/instrument/python/requirements.txt" "$WORK/rd/"
cd "$WORK/rd"
echo 'redis>=5' >> requirements.txt
printf 'import tracing\nfrom app import app\ntracing.instrument_fastapi(app)\n' > main.py
cp -R "$WORK/rd" "$WORK/rd-before"
"$WORK/venv/bin/pip" install -q --disable-pip-version-check -r requirements.txt
export REDIS_URL="${REDIS_URL:-redis://localhost:6379/0}" CACHE_PREFIX="enrich-e2e-$$"
if "$WORK/venv/bin/python" -c 'import os, redis; redis.Redis.from_url(os.environ["REDIS_URL"], socket_timeout=2).ping()' 2>/dev/null; then
  RV=$("$WORK/venv/bin/python" -c 'import redis; print(redis.__version__)')
  is "redis: redis is reported as a client whose package is not installed (redis-py $RV)" "$(status_of redis)" install
  py_run "$WORK/rd-before.log"; get http://localhost:8910/items/1 >/dev/null; stop
  is "redis: before, a request makes no client span" "$(py_clients "$WORK/rd-before.log")" 0

  export CACHE_PREFIX="enrich-e2e-$$-after"
  enrich client --root . --name redis --bootstrap tracing.py >/dev/null
  grep -q '^opentelemetry-instrumentation-redis>=0.66b2$' requirements.txt \
    && ok "redis: the requirement is pinned to the release the other instrumentation package uses" \
    || { bad "redis: requirement line missing or unpinned"; tail -4 requirements.txt; }
  "$WORK/venv/bin/pip" install -q --disable-pip-version-check -r requirements.txt
  is "redis: after the install, redis is reported as turned on" "$(status_of redis)" enabled

  py_run "$WORK/rd-after.log"
  # 1 misses (GET, SET), 1 hits (GET), 2 misses (GET, SET), 9 is not in the catalog (GET, no SET).
  codes="$(get http://localhost:8910/items/1) $(get http://localhost:8910/items/1) $(get http://localhost:8910/items/2) $(get http://localhost:8910/items/9)"
  stop
  is "redis: the service answers as before (three hits, one 404)" "$codes" "200 200 200 404"
  is "redis: six commands made exactly six client spans, one each, named after the command" \
    "$(client_names "$WORK/rd-after.log")" "GET=4 SET=2"
  "$WORK/venv/bin/python" -c 'import os, redis; r = redis.Redis.from_url(os.environ["REDIS_URL"]); [r.delete(k) for k in r.scan_iter("enrich-e2e-*")]' || true

  enrich remove --root . >/dev/null
  rm -rf __pycache__ "$WORK/rd-before/__pycache__"
  diff -r "$WORK/rd-before" "$WORK/rd" >/dev/null \
    && ok "redis: enrich.py remove restored the bootstrap and requirements.txt byte for byte" \
    || { bad "redis: files differ after removal"; diff -r "$WORK/rd-before" "$WORK/rd" | head; }
elif [ "${OTEL_AS_CODE_REQUIRE_REDIS:-}" = 1 ]; then
  bad "redis: no Redis server answered at $REDIS_URL, and OTEL_AS_CODE_REQUIRE_REDIS=1"
else
  echo "NOT CHECKED: redis (no server at $REDIS_URL; CI runs one)"
fi

# ---------------------------------------------------------------- Python, psycopg (Postgres)
# The same rule against a second server, the same way: CI runs Postgres as a service container and
# sets OTEL_AS_CODE_REQUIRE_POSTGRES=1; anywhere else this is "not checked".
mkdir -p "$WORK/pg"
cp "$SRC/tests/enrich/py-psycopg/app.py" "$SRC/tests/snapshots/instrument/python/tracing.py" \
   "$SRC/tests/snapshots/instrument/python/requirements.txt" "$WORK/pg/"
cd "$WORK/pg"
echo 'psycopg[binary]>=3.1' >> requirements.txt
printf 'import tracing\nfrom app import app\ntracing.instrument_fastapi(app)\n' > main.py
cp -R "$WORK/pg" "$WORK/pg-before"
"$WORK/venv/bin/pip" install -q --disable-pip-version-check -r requirements.txt
export DATABASE_URL="${DATABASE_URL:-postgresql://postgres:postgres@localhost:5432/postgres}" ITEMS_TABLE="enrich_e2e_$$"
if "$WORK/venv/bin/python" -c 'import os, psycopg; psycopg.connect(os.environ["DATABASE_URL"], connect_timeout=2).close()' 2>/dev/null; then
  PV=$("$WORK/venv/bin/python" -c 'import psycopg; print(psycopg.__version__)')
  is "psycopg: psycopg is reported as a client whose package is not installed (psycopg $PV)" "$(status_of psycopg)" install
  py_run "$WORK/pg-before.log"; get http://localhost:8910/items/1 >/dev/null; stop
  is "psycopg: before, a request makes no client span" "$(py_clients "$WORK/pg-before.log")" 0

  export ITEMS_TABLE="enrich_e2e_$$_after"
  enrich client --root . --name psycopg --bootstrap tracing.py >/dev/null
  grep -q '^opentelemetry-instrumentation-psycopg>=0.66b2$' requirements.txt \
    && ok "psycopg: the requirement is pinned to the release the other instrumentation package uses" \
    || { bad "psycopg: requirement line missing or unpinned"; tail -4 requirements.txt; }
  "$WORK/venv/bin/pip" install -q --disable-pip-version-check -r requirements.txt
  is "psycopg: after the install, psycopg is reported as turned on" "$(status_of psycopg)" enabled

  py_run "$WORK/pg-after.log"
  # Start-up: one CREATE and one INSERT (executemany). Then one SELECT per request, 9 not found.
  codes="$(get http://localhost:8910/items/1) $(get http://localhost:8910/items/1) $(get http://localhost:8910/items/2) $(get http://localhost:8910/items/9)"
  stop
  is "psycopg: the service answers as before (three found, one 404)" "$codes" "200 200 200 404"
  is "psycopg: four queries made exactly four SELECT spans, and only the start-up statements besides" \
    "$(client_names "$WORK/pg-after.log")" "CREATE=1 INSERT=1 SELECT=4"
  "$WORK/venv/bin/python" -c 'import os, psycopg
with psycopg.connect(os.environ["DATABASE_URL"], autocommit=True) as c:
    for (t,) in c.execute("SELECT tablename FROM pg_tables WHERE tablename LIKE %s", ("enrich_e2e_%",)).fetchall():
        c.execute(f"DROP TABLE {t}")' || true

  enrich remove --root . >/dev/null
  rm -rf __pycache__ "$WORK/pg-before/__pycache__"
  diff -r "$WORK/pg-before" "$WORK/pg" >/dev/null \
    && ok "psycopg: enrich.py remove restored the bootstrap and requirements.txt byte for byte" \
    || { bad "psycopg: files differ after removal"; diff -r "$WORK/pg-before" "$WORK/pg" | head; }
elif [ "${OTEL_AS_CODE_REQUIRE_POSTGRES:-}" = 1 ]; then
  bad "psycopg: no Postgres server answered at $DATABASE_URL, and OTEL_AS_CODE_REQUIRE_POSTGRES=1"
else
  echo "NOT CHECKED: psycopg (no server at $DATABASE_URL; CI runs one)"
fi

# ---------------------------------------------------------------- Python, asyncpg (Postgres)
# The first async client, on the same server: its package wraps asyncpg's own Connection methods,
# not a DB-API cursor like the three above.
# The server probe and the table cleanup use psycopg, which the section above put in the venv.
mkdir -p "$WORK/ap"
cp "$SRC/tests/enrich/py-asyncpg/app.py" "$SRC/tests/snapshots/instrument/python/tracing.py" \
   "$SRC/tests/snapshots/instrument/python/requirements.txt" "$WORK/ap/"
cd "$WORK/ap"
echo 'asyncpg>=0.30' >> requirements.txt
printf 'import tracing\nfrom app import app\ntracing.instrument_fastapi(app)\n' > main.py
cp -R "$WORK/ap" "$WORK/ap-before"
"$WORK/venv/bin/pip" install -q --disable-pip-version-check -r requirements.txt
export ITEMS_TABLE="enrich_e2e_$$_ap"
if "$WORK/venv/bin/python" -c 'import os, psycopg; psycopg.connect(os.environ["DATABASE_URL"], connect_timeout=2).close()' 2>/dev/null; then
  PV=$("$WORK/venv/bin/python" -c 'import asyncpg; print(asyncpg.__version__)')
  is "asyncpg: asyncpg is reported as a client whose package is not installed (asyncpg $PV)" "$(status_of asyncpg)" install
  py_run "$WORK/ap-before.log"; get http://localhost:8910/items/1 >/dev/null; stop
  is "asyncpg: before, a request makes no client span" "$(py_clients "$WORK/ap-before.log")" 0

  export ITEMS_TABLE="enrich_e2e_$$_ap_after"
  enrich client --root . --name asyncpg --bootstrap tracing.py >/dev/null
  grep -q '^opentelemetry-instrumentation-asyncpg>=0.66b2$' requirements.txt \
    && ok "asyncpg: the requirement is pinned to the release the other instrumentation package uses" \
    || { bad "asyncpg: requirement line missing or unpinned"; tail -4 requirements.txt; }
  "$WORK/venv/bin/pip" install -q --disable-pip-version-check -r requirements.txt
  is "asyncpg: after the install, asyncpg is reported as turned on" "$(status_of asyncpg)" enabled

  py_run "$WORK/ap-after.log"
  # Start-up: one CREATE and one INSERT (executemany). Then one SELECT per request, 9 not found.
  codes="$(get http://localhost:8910/items/1) $(get http://localhost:8910/items/1) $(get http://localhost:8910/items/2) $(get http://localhost:8910/items/9)"
  stop
  is "asyncpg: the service answers as before (three found, one 404)" "$codes" "200 200 200 404"
  is "asyncpg: four queries made exactly four SELECT spans, and only the start-up statements besides" \
    "$(client_names "$WORK/ap-after.log")" "CREATE=1 INSERT=1 SELECT=4"
  "$WORK/venv/bin/python" -c 'import os, psycopg
with psycopg.connect(os.environ["DATABASE_URL"], autocommit=True) as c:
    for (t,) in c.execute("SELECT tablename FROM pg_tables WHERE tablename LIKE %s", ("enrich_e2e_%",)).fetchall():
        c.execute(f"DROP TABLE {t}")' || true

  enrich remove --root . >/dev/null
  rm -rf __pycache__ "$WORK/ap-before/__pycache__"
  diff -r "$WORK/ap-before" "$WORK/ap" >/dev/null \
    && ok "asyncpg: enrich.py remove restored the bootstrap and requirements.txt byte for byte" \
    || { bad "asyncpg: files differ after removal"; diff -r "$WORK/ap-before" "$WORK/ap" | head; }
elif [ "${OTEL_AS_CODE_REQUIRE_POSTGRES:-}" = 1 ]; then
  bad "asyncpg: no Postgres server answered at $DATABASE_URL, and OTEL_AS_CODE_REQUIRE_POSTGRES=1"
else
  echo "NOT CHECKED: asyncpg (no server at $DATABASE_URL; CI runs one)"
fi

# ---------------------------------------------------------------- Python, psycopg2 (Postgres)
# The DB-API driver aiopg runs on, used directly: with no aiopg in the service it is not layered.
# The server probe and the table cleanup use psycopg, which a section above put in the venv.
mkdir -p "$WORK/p2"
cp "$SRC/tests/enrich/py-psycopg2/app.py" "$SRC/tests/snapshots/instrument/python/tracing.py" \
   "$SRC/tests/snapshots/instrument/python/requirements.txt" "$WORK/p2/"
cd "$WORK/p2"
echo 'psycopg2-binary>=2.9' >> requirements.txt
printf 'import tracing\nfrom app import app\ntracing.instrument_fastapi(app)\n' > main.py
cp -R "$WORK/p2" "$WORK/p2-before"
"$WORK/venv/bin/pip" install -q --disable-pip-version-check -r requirements.txt
export ITEMS_TABLE="enrich_e2e_$$_p2"
if "$WORK/venv/bin/python" -c 'import os, psycopg; psycopg.connect(os.environ["DATABASE_URL"], connect_timeout=2).close()' 2>/dev/null; then
  PV=$("$WORK/venv/bin/python" -c 'import psycopg2; print(psycopg2.__version__.split()[0])')
  is "psycopg2: psycopg2 is reported as a client whose package is not installed (psycopg2 $PV)" "$(status_of psycopg2)" install
  py_run "$WORK/p2-before.log"; get http://localhost:8910/items/1 >/dev/null; stop
  is "psycopg2: before, a request makes no client span" "$(py_clients "$WORK/p2-before.log")" 0

  export ITEMS_TABLE="enrich_e2e_$$_p2_after"
  enrich client --root . --name psycopg2 --bootstrap tracing.py >/dev/null
  grep -q '^opentelemetry-instrumentation-psycopg2>=0.66b2$' requirements.txt \
    && ok "psycopg2: the requirement is pinned to the release the other instrumentation package uses" \
    || { bad "psycopg2: requirement line missing or unpinned"; tail -4 requirements.txt; }
  "$WORK/venv/bin/pip" install -q --disable-pip-version-check -r requirements.txt
  is "psycopg2: after the install, psycopg2 is reported as turned on" "$(status_of psycopg2)" enabled

  py_run "$WORK/p2-after.log"
  # Start-up: one CREATE and one INSERT (executemany). Then one SELECT per request, 9 not found.
  codes="$(get http://localhost:8910/items/1) $(get http://localhost:8910/items/1) $(get http://localhost:8910/items/2) $(get http://localhost:8910/items/9)"
  stop
  is "psycopg2: the service answers as before (three found, one 404)" "$codes" "200 200 200 404"
  is "psycopg2: four queries made exactly four SELECT spans, and only the start-up statements besides" \
    "$(client_names "$WORK/p2-after.log")" "CREATE=1 INSERT=1 SELECT=4"
  "$WORK/venv/bin/python" -c 'import os, psycopg
with psycopg.connect(os.environ["DATABASE_URL"], autocommit=True) as c:
    for (t,) in c.execute("SELECT tablename FROM pg_tables WHERE tablename LIKE %s", ("enrich_e2e_%",)).fetchall():
        c.execute(f"DROP TABLE {t}")' || true

  enrich remove --root . >/dev/null
  rm -rf __pycache__ "$WORK/p2-before/__pycache__"
  diff -r "$WORK/p2-before" "$WORK/p2" >/dev/null \
    && ok "psycopg2: enrich.py remove restored the bootstrap and requirements.txt byte for byte" \
    || { bad "psycopg2: files differ after removal"; diff -r "$WORK/p2-before" "$WORK/p2" | head; }
elif [ "${OTEL_AS_CODE_REQUIRE_POSTGRES:-}" = 1 ]; then
  bad "psycopg2: no Postgres server answered at $DATABASE_URL, and OTEL_AS_CODE_REQUIRE_POSTGRES=1"
else
  echo "NOT CHECKED: psycopg2 (no server at $DATABASE_URL; CI runs one)"
fi

# ---------------------------------------------------------------- Python, aiopg (Postgres)
# aiopg runs psycopg2 connections in async mode, and psycopg2 has a package of its own. Measured in
# CI (#322): both on gave two spans per query and one more per connection (CREATE=2 INSERT=4
# SELECT=13), so psycopg2 is layered under aiopg in client-coverage.json and turning it on is
# refused. aiopg is capped below 2 (its package's range), or it would read as "pin".
# The server probe and the table cleanup use psycopg, which a section above put in the venv.
mkdir -p "$WORK/ao"
cp "$SRC/tests/enrich/py-aiopg/app.py" "$SRC/tests/snapshots/instrument/python/tracing.py" \
   "$SRC/tests/snapshots/instrument/python/requirements.txt" "$WORK/ao/"
cd "$WORK/ao"
printf 'aiopg>=1.4,<2\npsycopg2-binary>=2.9\n' >> requirements.txt
printf 'import tracing\nfrom app import app\ntracing.instrument_fastapi(app)\n' > main.py
cp -R "$WORK/ao" "$WORK/ao-before"
"$WORK/venv/bin/pip" install -q --disable-pip-version-check -r requirements.txt
export ITEMS_TABLE="enrich_e2e_$$_ao"
if "$WORK/venv/bin/python" -c 'import os, psycopg; psycopg.connect(os.environ["DATABASE_URL"], connect_timeout=2).close()' 2>/dev/null; then
  PV=$("$WORK/venv/bin/python" -c 'import aiopg; print(aiopg.__version__)')
  is "aiopg: aiopg is reported as a client whose package is not installed (aiopg $PV)" "$(status_of aiopg)" install
  py_run "$WORK/ao-before.log"; get http://localhost:8910/items/1 >/dev/null; stop
  is "aiopg: before, a request makes no client span" "$(py_clients "$WORK/ao-before.log")" 0

  export ITEMS_TABLE="enrich_e2e_$$_ao_after"
  enrich client --root . --name aiopg --bootstrap tracing.py >/dev/null
  grep -q '^opentelemetry-instrumentation-aiopg>=0.66b2$' requirements.txt \
    && ok "aiopg: the requirement is pinned to the release the other instrumentation package uses" \
    || { bad "aiopg: requirement line missing or unpinned"; tail -4 requirements.txt; }
  "$WORK/venv/bin/pip" install -q --disable-pip-version-check -r requirements.txt
  is "aiopg: after the install, aiopg is reported as turned on" "$(status_of aiopg)" enabled

  py_run "$WORK/ao-after.log"
  # Start-up: one CREATE and one INSERT per row (aiopg has no executemany). Then one SELECT per request, 9 not found.
  codes="$(get http://localhost:8910/items/1) $(get http://localhost:8910/items/1) $(get http://localhost:8910/items/2) $(get http://localhost:8910/items/9)"
  stop
  is "aiopg: the service answers as before (three found, one 404)" "$codes" "200 200 200 404"
  is "aiopg: four queries made exactly four SELECT spans, and only the start-up statements besides" \
    "$(client_names "$WORK/ao-after.log")" "CREATE=1 INSERT=2 SELECT=4"
  is "aiopg: psycopg2 under it is reported as layered" "$(status_of psycopg2)" layered
  out=$(enrich client --root . --name psycopg2 --bootstrap tracing.py 2>&1) && rc=0 || rc=$?
  { [ "$rc" = 2 ] && printf '%s' "$out" | grep -q "two spans per query"; } \
    && ok "aiopg: turning psycopg2 on under it is refused" || bad "aiopg: psycopg2 was not refused: $out"
  "$WORK/venv/bin/python" -c 'import os, psycopg
with psycopg.connect(os.environ["DATABASE_URL"], autocommit=True) as c:
    for (t,) in c.execute("SELECT tablename FROM pg_tables WHERE tablename LIKE %s", ("enrich_e2e_%",)).fetchall():
        c.execute(f"DROP TABLE {t}")' || true

  enrich remove --root . >/dev/null
  rm -rf __pycache__ "$WORK/ao-before/__pycache__"
  diff -r "$WORK/ao-before" "$WORK/ao" >/dev/null \
    && ok "aiopg: enrich.py remove restored the bootstrap and requirements.txt byte for byte" \
    || { bad "aiopg: files differ after removal"; diff -r "$WORK/ao-before" "$WORK/ao" | head; }
elif [ "${OTEL_AS_CODE_REQUIRE_POSTGRES:-}" = 1 ]; then
  bad "aiopg: no Postgres server answered at $DATABASE_URL, and OTEL_AS_CODE_REQUIRE_POSTGRES=1"
else
  echo "NOT CHECKED: aiopg (no server at $DATABASE_URL; CI runs one)"
fi

# ---------------------------------------------------------------- Python, PyMySQL (MySQL)
# A third server, the same way: CI runs MySQL as a service container and sets
# OTEL_AS_CODE_REQUIRE_MYSQL=1; anywhere else this is "not checked". The requirement is capped
# below 2, the package's range, or it would read as "pin"; the rsa extra is what MySQL 8's default
# authentication needs over a plain connection.
# PyMySQL's __version__ is a MySQLdb-compatible "2.2.8"; its own version is VERSION_STRING.
mkdir -p "$WORK/my"
cp "$SRC/tests/enrich/py-pymysql/app.py" "$SRC/tests/snapshots/instrument/python/tracing.py" \
   "$SRC/tests/snapshots/instrument/python/requirements.txt" "$WORK/my/"
cd "$WORK/my"
echo 'PyMySQL[rsa]>=1.1,<2' >> requirements.txt
printf 'import tracing\nfrom app import app\ntracing.instrument_fastapi(app)\n' > main.py
cp -R "$WORK/my" "$WORK/my-before"
"$WORK/venv/bin/pip" install -q --disable-pip-version-check -r requirements.txt
export MYSQL_HOST="${MYSQL_HOST:-127.0.0.1}" MYSQL_PASSWORD="${MYSQL_PASSWORD:-mysql}" MYSQL_DATABASE="${MYSQL_DATABASE:-catalog}" ITEMS_TABLE="enrich_e2e_$$_my"
if "$WORK/venv/bin/python" -c 'import os, pymysql; pymysql.connect(host=os.environ["MYSQL_HOST"], user="root", password=os.environ["MYSQL_PASSWORD"], database=os.environ["MYSQL_DATABASE"], connect_timeout=2).close()' 2>/dev/null; then
  PV=$("$WORK/venv/bin/python" -c 'import pymysql; print(pymysql.VERSION_STRING)')
  is "pymysql: pymysql is reported as a client whose package is not installed (PyMySQL $PV)" "$(status_of pymysql)" install
  py_run "$WORK/my-before.log"; get http://localhost:8910/items/1 >/dev/null; stop
  is "pymysql: before, a request makes no client span" "$(py_clients "$WORK/my-before.log")" 0

  export ITEMS_TABLE="enrich_e2e_$$_my_after"
  enrich client --root . --name pymysql --bootstrap tracing.py >/dev/null
  grep -q '^opentelemetry-instrumentation-pymysql>=0.66b2$' requirements.txt \
    && ok "pymysql: the requirement is pinned to the release the other instrumentation package uses" \
    || { bad "pymysql: requirement line missing or unpinned"; tail -4 requirements.txt; }
  "$WORK/venv/bin/pip" install -q --disable-pip-version-check -r requirements.txt
  is "pymysql: after the install, pymysql is reported as turned on" "$(status_of pymysql)" enabled

  py_run "$WORK/my-after.log"
  # Start-up: one CREATE and one INSERT (executemany, which PyMySQL sends as one statement). Then one SELECT per request, 9 not found.
  codes="$(get http://localhost:8910/items/1) $(get http://localhost:8910/items/1) $(get http://localhost:8910/items/2) $(get http://localhost:8910/items/9)"
  stop
  is "pymysql: the service answers as before (three found, one 404)" "$codes" "200 200 200 404"
  is "pymysql: four queries made exactly four SELECT spans, and only the start-up statements besides" \
    "$(client_names "$WORK/my-after.log")" "CREATE=1 INSERT=1 SELECT=4"
  "$WORK/venv/bin/python" -c 'import os, pymysql
c = pymysql.connect(host=os.environ["MYSQL_HOST"], user="root", password=os.environ["MYSQL_PASSWORD"], database=os.environ["MYSQL_DATABASE"])
with c.cursor() as cur:
    cur.execute("SELECT table_name FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name LIKE %s", ("enrich_e2e_%",))
    for (t,) in cur.fetchall():
        cur.execute(f"DROP TABLE {t}")' || true

  enrich remove --root . >/dev/null
  rm -rf __pycache__ "$WORK/my-before/__pycache__"
  diff -r "$WORK/my-before" "$WORK/my" >/dev/null \
    && ok "pymysql: enrich.py remove restored the bootstrap and requirements.txt byte for byte" \
    || { bad "pymysql: files differ after removal"; diff -r "$WORK/my-before" "$WORK/my" | head; }
elif [ "${OTEL_AS_CODE_REQUIRE_MYSQL:-}" = 1 ]; then
  bad "pymysql: no MySQL server answered at $MYSQL_HOST, and OTEL_AS_CODE_REQUIRE_MYSQL=1"
else
  echo "NOT CHECKED: pymysql (no server at $MYSQL_HOST; CI runs one)"
fi

# ---------------------------------------------------------------- Python, mysql-connector-python (MySQL)
# Oracle's driver on the same server. Its default connection class is its C extension; the package
# wraps mysql.connector.connect, so this also shows that connection gets spans. The server probe and
# the table cleanup use PyMySQL, which the section above put in the venv.
mkdir -p "$WORK/mc"
cp "$SRC/tests/enrich/py-mysql-connector/app.py" "$SRC/tests/snapshots/instrument/python/tracing.py" \
   "$SRC/tests/snapshots/instrument/python/requirements.txt" "$WORK/mc/"
cd "$WORK/mc"
echo 'mysql-connector-python>=9' >> requirements.txt
printf 'import tracing\nfrom app import app\ntracing.instrument_fastapi(app)\n' > main.py
cp -R "$WORK/mc" "$WORK/mc-before"
"$WORK/venv/bin/pip" install -q --disable-pip-version-check -r requirements.txt
export ITEMS_TABLE="enrich_e2e_$$_mc"
if "$WORK/venv/bin/python" -c 'import os, pymysql; pymysql.connect(host=os.environ["MYSQL_HOST"], user="root", password=os.environ["MYSQL_PASSWORD"], database=os.environ["MYSQL_DATABASE"], connect_timeout=2).close()' 2>/dev/null; then
  PV=$("$WORK/venv/bin/python" -c 'import mysql.connector; print(mysql.connector.__version__)')
  is "mysql-connector: mysql-connector-python is reported as a client whose package is not installed (mysql-connector-python $PV)" "$(status_of mysql-connector-python)" install
  py_run "$WORK/mc-before.log"; get http://localhost:8910/items/1 >/dev/null; stop
  is "mysql-connector: before, a request makes no client span" "$(py_clients "$WORK/mc-before.log")" 0

  export ITEMS_TABLE="enrich_e2e_$$_mc_after"
  enrich client --root . --name mysql-connector-python --bootstrap tracing.py >/dev/null
  grep -q '^opentelemetry-instrumentation-mysql>=0.66b2$' requirements.txt \
    && ok "mysql-connector: the requirement is pinned to the release the other instrumentation package uses" \
    || { bad "mysql-connector: requirement line missing or unpinned"; tail -4 requirements.txt; }
  "$WORK/venv/bin/pip" install -q --disable-pip-version-check -r requirements.txt
  is "mysql-connector: after the install, mysql-connector-python is reported as turned on" "$(status_of mysql-connector-python)" enabled

  py_run "$WORK/mc-after.log"
  # Start-up: one CREATE and one INSERT (executemany, which the driver sends as one statement). Then one SELECT per request, 9 not found.
  codes="$(get http://localhost:8910/items/1) $(get http://localhost:8910/items/1) $(get http://localhost:8910/items/2) $(get http://localhost:8910/items/9)"
  stop
  is "mysql-connector: the service answers as before (three found, one 404)" "$codes" "200 200 200 404"
  is "mysql-connector: four queries made exactly four SELECT spans, and only the start-up statements besides" \
    "$(client_names "$WORK/mc-after.log")" "CREATE=1 INSERT=1 SELECT=4"
  "$WORK/venv/bin/python" -c 'import os, pymysql
c = pymysql.connect(host=os.environ["MYSQL_HOST"], user="root", password=os.environ["MYSQL_PASSWORD"], database=os.environ["MYSQL_DATABASE"])
with c.cursor() as cur:
    cur.execute("SELECT table_name FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name LIKE %s", ("enrich_e2e_%",))
    for (t,) in cur.fetchall():
        cur.execute(f"DROP TABLE {t}")' || true

  enrich remove --root . >/dev/null
  rm -rf __pycache__ "$WORK/mc-before/__pycache__"
  diff -r "$WORK/mc-before" "$WORK/mc" >/dev/null \
    && ok "mysql-connector: enrich.py remove restored the bootstrap and requirements.txt byte for byte" \
    || { bad "mysql-connector: files differ after removal"; diff -r "$WORK/mc-before" "$WORK/mc" | head; }
elif [ "${OTEL_AS_CODE_REQUIRE_MYSQL:-}" = 1 ]; then
  bad "mysql-connector: no MySQL server answered at $MYSQL_HOST, and OTEL_AS_CODE_REQUIRE_MYSQL=1"
else
  echo "NOT CHECKED: mysql-connector-python (no server at $MYSQL_HOST; CI runs one)"
fi

# ---------------------------------------------------------------- Python, mysqlclient (MySQL)
# The C driver (MySQLdb) on the same server. It builds against libmysqlclient, which CI installs;
# where the build fails, this is "not checked" like a missing server. The server probe and the
# table cleanup use PyMySQL, which a section above put in the venv.
mkdir -p "$WORK/mq"
cp "$SRC/tests/enrich/py-mysqlclient/app.py" "$SRC/tests/snapshots/instrument/python/tracing.py" \
   "$SRC/tests/snapshots/instrument/python/requirements.txt" "$WORK/mq/"
cd "$WORK/mq"
echo 'mysqlclient>=2.2,<3' >> requirements.txt
printf 'import tracing\nfrom app import app\ntracing.instrument_fastapi(app)\n' > main.py
cp -R "$WORK/mq" "$WORK/mq-before"
mq_built=no
"$WORK/venv/bin/pip" install -q --disable-pip-version-check -r requirements.txt >"$WORK/mq-pip.log" 2>&1 && mq_built=yes
export ITEMS_TABLE="enrich_e2e_$$_mq"
if [ "$mq_built" = yes ] && "$WORK/venv/bin/python" -c 'import os, pymysql; pymysql.connect(host=os.environ["MYSQL_HOST"], user="root", password=os.environ["MYSQL_PASSWORD"], database=os.environ["MYSQL_DATABASE"], connect_timeout=2).close()' 2>/dev/null; then
  PV=$("$WORK/venv/bin/python" -c 'from importlib.metadata import version; print(version("mysqlclient"))')
  is "mysqlclient: mysqlclient is reported as a client whose package is not installed (mysqlclient $PV)" "$(status_of mysqlclient)" install
  py_run "$WORK/mq-before.log"; get http://localhost:8910/items/1 >/dev/null; stop
  is "mysqlclient: before, a request makes no client span" "$(py_clients "$WORK/mq-before.log")" 0

  export ITEMS_TABLE="enrich_e2e_$$_mq_after"
  enrich client --root . --name mysqlclient --bootstrap tracing.py >/dev/null
  grep -q '^opentelemetry-instrumentation-mysqlclient>=0.66b2$' requirements.txt \
    && ok "mysqlclient: the requirement is pinned to the release the other instrumentation package uses" \
    || { bad "mysqlclient: requirement line missing or unpinned"; tail -4 requirements.txt; }
  "$WORK/venv/bin/pip" install -q --disable-pip-version-check -r requirements.txt
  is "mysqlclient: after the install, mysqlclient is reported as turned on" "$(status_of mysqlclient)" enabled

  py_run "$WORK/mq-after.log"
  # Start-up: one CREATE and one INSERT (executemany, which the driver sends as one statement). Then one SELECT per request, 9 not found.
  codes="$(get http://localhost:8910/items/1) $(get http://localhost:8910/items/1) $(get http://localhost:8910/items/2) $(get http://localhost:8910/items/9)"
  stop
  is "mysqlclient: the service answers as before (three found, one 404)" "$codes" "200 200 200 404"
  is "mysqlclient: four queries made exactly four SELECT spans, and only the start-up statements besides" \
    "$(client_names "$WORK/mq-after.log")" "CREATE=1 INSERT=1 SELECT=4"
  "$WORK/venv/bin/python" -c 'import os, pymysql
c = pymysql.connect(host=os.environ["MYSQL_HOST"], user="root", password=os.environ["MYSQL_PASSWORD"], database=os.environ["MYSQL_DATABASE"])
with c.cursor() as cur:
    cur.execute("SELECT table_name FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name LIKE %s", ("enrich_e2e_%",))
    for (t,) in cur.fetchall():
        cur.execute(f"DROP TABLE {t}")' || true

  enrich remove --root . >/dev/null
  rm -rf __pycache__ "$WORK/mq-before/__pycache__"
  diff -r "$WORK/mq-before" "$WORK/mq" >/dev/null \
    && ok "mysqlclient: enrich.py remove restored the bootstrap and requirements.txt byte for byte" \
    || { bad "mysqlclient: files differ after removal"; diff -r "$WORK/mq-before" "$WORK/mq" | head; }
elif [ "${OTEL_AS_CODE_REQUIRE_MYSQL:-}" = 1 ]; then
  tail -5 "$WORK/mq-pip.log"
  bad "mysqlclient: no MySQL server answered at $MYSQL_HOST or mysqlclient did not build, and OTEL_AS_CODE_REQUIRE_MYSQL=1"
else
  echo "NOT CHECKED: mysqlclient (no server at $MYSQL_HOST, or no libmysqlclient to build against; CI has both)"
fi

# ---------------------------------------------------------------- Node.js
mkdir -p "$WORK/node"
cp -R "$SRC/tests/enrich/node-clients/." "$WORK/node/"
cp "$SRC/tests/snapshots/instrument/nodejs/tracing.js" "$WORK/node/tracing.js"
cd "$WORK/node"
is "node: before the install, pg's coverage is reported as not checked" "$(status_of pg --bootstrap tracing.js)" not-checked
npm install --no-audit --no-fund --loglevel=error
cp -R "$WORK/node" "$WORK/node-before"
is "node: pg is covered by the bundle the bootstrap loads" "$(status_of pg --bootstrap tracing.js)" covered
is "node: node:sqlite has no package and is offered a client span" "$(status_of node:sqlite --bootstrap tracing.js)" wrap
SPAN=(--root . --file lib/store.js --function findItem --span-name store.findItem --tracer-name enrich-catalog)
out=$(enrich span "${SPAN[@]}" --client pg 2>&1) && rc=0 || rc=$?
{ [ "$rc" = 2 ] && printf '%s' "$out" | grep -q "two client spans per call"; } \
  && ok "node: a hand-made span for a client the bundle covers is refused" || bad "node: --client pg was not refused: $out"
enrich span "${SPAN[@]}" --client node:sqlite >/dev/null
OTEL_TRACES_EXPORTER=console OTEL_METRICS_EXPORTER=none OTEL_SERVICE_NAME=enrich-catalog PORT=3910 \
  node -r ./tracing.js index.js > "$WORK/node.log" 2>&1 & APP_PID=$!
wait_up http://localhost:3910/health || { bad "node: the service did not start"; cat "$WORK/node.log"; }
codes="$(get http://localhost:3910/items/1) $(get http://localhost:3910/items/2) $(get http://localhost:3910/items/9)"
stop
is "node: the service answers as before (two hits, one 404)" "$codes" "200 200 404"
is "node: three calls made exactly three client spans, one each" "$(grep -c '^ *kind: 2,' "$WORK/node.log" || true)" 3
is "node: each one is the span around findItem, marked as a SQLite call" \
  "$(grep -c "name: 'store.findItem'" "$WORK/node.log" || true) $(grep -c "'db.system.name': 'sqlite'" "$WORK/node.log" || true)" "3 3"
enrich remove --root . >/dev/null
diff -r "$WORK/node-before" "$WORK/node" >/dev/null \
  && ok "node: enrich.py remove restored every file byte for byte" || { bad "node: files differ after removal"; diff -r "$WORK/node-before" "$WORK/node" | head; }

[ "$failed" -eq 0 ] && echo "ENRICH CLIENTS E2E PASS: one client span per call, and removal restored the code"
exit "$failed"
