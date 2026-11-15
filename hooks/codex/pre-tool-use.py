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
# hooks/otel-context-check.py), the same code as the Claude Code path. A direct Edit/Write is
# passed through unchanged, so the check sees what Claude Code would send. An apply_patch that
# could reach the cache is let through only as one full-file Add of the cache, whose content the
# check reads; an Update, Move or Delete of it is denied (#254), since checking a diff would mean a
# second patch parser that can disagree with apply_patch. post-tool-use.py re-checks the file on
# disk after every patch that reaches it.
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _bridge import bridge_env, cache_add, is_context_path, parse_targets, reaches_cache, read_payload, run_hook


CACHE_PATCH_REASON = (
    "otel-as-code write-guard: this patch changes .claude/otel-context.json in a way whose business "
    "attributes can't be checked before it lands (an Update, Move or Delete, or an Add mixed with "
    "other changes). Write the cache with scripts/write_context.py, as the /otel-* commands do, or "
    "as a single full-file \"*** Add File: .claude/otel-context.json\" patch."
)


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
    if reaches_cache(tool_input, cwd):
        if direct and not is_context_path(tool_input["file_path"]):
            deny("otel-as-code write-guard: this write reaches .claude/otel-context.json through "
                 "another name (a link or an alias), so its business attributes can't be checked. "
                 "Write the cache by its own path.")
            return
        if not direct and cache_add(tool_input.get("command")) is None:
            deny(CACHE_PATCH_REASON)
            return
    for path, content in parse_targets(tool_input):
        proc = run_hook("write-guard.sh", path, content, cwd, env, tool=direct)
        if proc.returncode == 2:  # exit 2 = block/fail-closed in write-guard.sh
            deny((proc.stderr or "otel-as-code guardrail blocked this write.").strip())
            return  # deny wins on the first blocked target


if __name__ == "__main__":
    main()
