#!/usr/bin/env bash
# hooks/otel-python.sh
# Finds a Python that ACTUALLY RUNS, for the hooks that parse their JSON payload with it (jq is
# not assumed). Sourced by write-guard.sh and semconv-lint.sh so the probe cannot drift between
# them; each hook decides for itself what to do when none is found.
#
# `command -v` is NOT sufficient: on Windows `python3` is commonly an App Execution Alias stub
# that is on PATH and resolves, but errors at run time ("Python was not found; run without
# arguments to install from the Microsoft Store"). Trusting PATH there left the parse empty and
# the guard silently allowed every write (#33). So each candidate is verified by executing it,
# and the first WORKING one wins (a real Python is frequently `python` when `python3` is the stub).
#
# The interpreter is only ever run by its literal name, `python3` or `python`, so the plugin
# directory can see what runs. OTEL_HOOK_PYTHON (the path of a python3/python outside PATH) puts
# that interpreter's folder first on PATH rather than being executed as a variable.
#
# Sets PY to python3, python, or "" (none works), and defines py() to run it.
if [ -n "${OTEL_HOOK_PYTHON:-}" ]; then PATH="$(dirname "$OTEL_HOOK_PYTHON"):$PATH"; fi
PY=""
if python3 -c 'pass' </dev/null >/dev/null 2>/dev/null; then PY=python3
elif python -c 'pass' </dev/null >/dev/null 2>/dev/null; then PY=python
fi
py() { if [ "$PY" = python3 ]; then python3 "$@"; else python "$@"; fi; }
