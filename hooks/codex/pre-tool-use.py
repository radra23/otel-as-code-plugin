#!/usr/bin/env python3
# hooks/codex/pre-tool-use.py
# Codex PreToolUse adapter for otel-as-code.
#
# Parses Codex's apply_patch payload and runs hooks/write-guard.sh (overwrite protection +
# confirm-before-write) on each write target, mapping a block (exit 2 — the Claude Code
# block/fail-closed code the shell hook uses) to Codex's
# { hookSpecificOutput.permissionDecision: "deny" }. Shared plumbing lives in _bridge.py.
#
# The confirm-before-write check on otel-context.json runs in write-guard.sh (through
# hooks/otel-context-check.py), the same code as the Claude Code path; this adapter only hands it
# the file as the write would leave it: the patch is replayed in order from the files on disk
# (#254), and a direct Edit/Write is passed through unchanged. An Update to the cache whose result
# can't be known (lines not found, or found in more than one place) can't be checked, so it is
# denied rather than let through.
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _bridge import AMBIGUOUS, UNAPPLIED, bridge_env, is_context_path, parse_targets, read_payload, run_hook


def deny(reason):
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": reason,
    }}))


def main():
    payload = read_payload()
    tool_input = payload.get("tool_input") or {}
    cwd = payload.get("cwd") or os.getcwd()
    env = bridge_env(cwd)
    direct = (payload.get("tool_name"), tool_input) if tool_input.get("file_path") else None
    for path, content in parse_targets(tool_input, cwd):
        if content is UNAPPLIED or content is AMBIGUOUS:
            if is_context_path(path):
                why = ("its lines match more than one place in the file, so where the change lands "
                       "can't be known" if content is AMBIGUOUS else "its lines are not in the file")
                deny(f"otel-as-code write-guard: could not check this patch to {path} for "
                     f"unconfirmed business attributes ({why}), so it is not let through. Add more "
                     "context lines, rewrite the file with its full content, or re-run "
                     "/otel-business-attrs.")
                return
            content = None
        proc = run_hook("write-guard.sh", path, content, cwd, env, tool=direct)
        if proc.returncode == 2:  # exit 2 = block/fail-closed in write-guard.sh
            deny((proc.stderr or "otel-as-code guardrail blocked this write.").strip())
            return  # deny wins on the first blocked target


if __name__ == "__main__":
    main()
