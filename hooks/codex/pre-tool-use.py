#!/usr/bin/env python3
# hooks/codex/pre-tool-use.py
# Codex PreToolUse adapter for otel-as-code.
#
# Parses Codex's apply_patch payload and runs hooks/write-guard.sh (overwrite protection +
# confirm-before-write) on each write target, mapping a block (exit 1) to Codex's
# { hookSpecificOutput.permissionDecision: "deny" }. Shared plumbing lives in _bridge.py.
#
# Scope: apply_patch "Update" hunks give a diff, not full content, so the confirm-before-write
# check on otel-context.json only fires for whole-file writes ("Add File" / Write with content).
# Overwrite protection works for all cases (it needs only the target path + on-disk existence).
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
    for path, content in parse_targets(tool_input):
        proc = run_hook("write-guard.sh", path, content, cwd, env)
        if proc.returncode == 1:
            reason = (proc.stderr or "otel-as-code guardrail blocked this write.").strip()
            print(json.dumps({"hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "deny",
                "permissionDecisionReason": reason,
            }}))
            return  # deny wins on the first blocked target


if __name__ == "__main__":
    main()
