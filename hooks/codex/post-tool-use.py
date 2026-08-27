#!/usr/bin/env python3
# hooks/codex/post-tool-use.py
# Codex PostToolUse adapter for otel-as-code.
#
# Runs the advisory hooks/semconv-lint.sh on each written OTel file (semconv-lint.sh reads the
# file from disk, already written by PostToolUse time) and surfaces any warnings back to the
# model via Codex's { hookSpecificOutput.additionalContext }. Shared plumbing lives in _bridge.py.
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _bridge import bridge_env, parse_targets, read_payload, run_hook


def main():
    payload = read_payload()
    tool_input = payload.get("tool_input") or {}
    cwd = payload.get("cwd") or os.getcwd()
    env = bridge_env(cwd)
    out = []
    for path, _content in parse_targets(tool_input):
        proc = run_hook("semconv-lint.sh", path, None, cwd, env)
        if proc.stdout.strip():
            out.append(proc.stdout.strip())
    if out:
        print(json.dumps({"hookSpecificOutput": {
            "hookEventName": "PostToolUse",
            "additionalContext": "otel-as-code semconv-lint:\n" + "\n\n".join(out),
        }}))


if __name__ == "__main__":
    main()
