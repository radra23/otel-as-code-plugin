#!/usr/bin/env python3
# hooks/codex/post-tool-use.py
# Codex PostToolUse adapter for otel-as-code.
#
# Runs the advisory semconv lint on OTel files after they are written and surfaces any
# warnings back to the model via Codex's { hookSpecificOutput.additionalContext }. Reuses
# hooks/semconv-lint.sh (single source of the lint rules + SEMCONV_VERSION); that script
# reads the file from disk, which is already written by PostToolUse time.
import json
import os
import re
import subprocess
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
SEMCONV_LINT = os.path.join(ROOT, "hooks", "semconv-lint.sh")


def parse_paths(tool_input):
    paths = []
    fp = tool_input.get("file_path")
    if fp:
        paths.append(fp)
    cmd = tool_input.get("command")
    if isinstance(cmd, str):
        for line in cmd.splitlines():
            m = re.match(r"^\*\*\* (?:Add|Update) File: (.+)$", line)
            mv = re.match(r"^\*\*\* Move to: (.+)$", line)
            if m:
                paths.append(m.group(1).strip())
            elif mv:
                paths.append(mv.group(1).strip())
    return paths


def main():
    try:
        payload = json.load(sys.stdin)
    except Exception:
        sys.exit(0)
    tool_input = payload.get("tool_input") or {}
    cwd = payload.get("cwd") or os.getcwd()
    env = dict(os.environ)
    env["CLAUDE_PLUGIN_ROOT"] = ROOT
    env["CLAUDE_PROJECT_DIR"] = cwd

    out = []
    for p in parse_paths(tool_input):
        synth = {"tool_name": "Write", "tool_input": {"file_path": p}}
        proc = subprocess.run(
            ["bash", SEMCONV_LINT], input=json.dumps(synth),
            text=True, capture_output=True, cwd=cwd, env=env,
        )
        if proc.stdout.strip():
            out.append(proc.stdout.strip())
    if out:
        print(json.dumps({"hookSpecificOutput": {
            "hookEventName": "PostToolUse",
            "additionalContext": "otel-as-code semconv-lint:\n" + "\n\n".join(out),
        }}))
    sys.exit(0)


if __name__ == "__main__":
    main()
