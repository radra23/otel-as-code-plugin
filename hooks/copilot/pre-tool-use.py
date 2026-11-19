#!/usr/bin/env python3
# hooks/copilot/pre-tool-use.py
# GitHub Copilot CLI preToolUse adapter for otel-as-code.
#
# Maps Copilot's `create`/`edit` to Claude's Write/Edit and runs hooks/write-guard.sh (overwrite
# protection + confirm-before-write on the context cache) on it, unchanged. A block (exit 2 +
# stderr) becomes Copilot's top-level {"permissionDecision": "deny"} on stdout: on Copilot CLI
# 1.0.56 exit 2 is logged and the write still runs, and only the JSON denies
# (docs/agents/copilot-spike.md, rows 3a/3b). Shared plumbing lives in _copilot.py.
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _copilot import bridge_env, claude_tool, is_context_path, read_payload, resolves_to_cache, run_hook


def deny(reason):
    print(json.dumps({"permissionDecision": "deny", "permissionDecisionReason": reason}))


def main():
    payload = read_payload()
    tool = claude_tool(payload)
    if tool is None:
        return
    # The hook process runs in the plugin's install folder; the user's repo is the payload's cwd.
    cwd = payload.get("cwd") or os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()
    path = tool[1]["file_path"]
    if resolves_to_cache(path, cwd) and not is_context_path(path):
        deny("otel-as-code write-guard: this write reaches .claude/otel-context.json through "
             "another name (a link or an alias), so its business attributes can't be checked. "
             "Write the cache by its own path.")
        return
    proc = run_hook("write-guard.sh", path, None, cwd, bridge_env(cwd), tool=tool)
    if proc.returncode == 2:  # exit 2 = block in write-guard.sh; any other code allows, as in Claude Code
        deny((proc.stderr or "otel-as-code guardrail blocked this write.").strip())


def on_bridge_error(exc):
    """Decide what Copilot sees when this adapter itself fails (a bug here, a missing python3
    module, an unreadable plugin file), as opposed to write-guard.sh deciding to block.

    Allow: print nothing and return; the write goes ahead unchecked.
    Deny:  deny("...") with a reason the model will show the user; the write is refused.
    Raising (the default below) exits non-zero, which Copilot's docs say denies (not measured).
    """
    # TODO: choose fail-open or fail-closed (or a mix, e.g. by whether the target is a
    # generated file or the context cache). See the PR description for the trade-off.
    raise exc


if __name__ == "__main__":
    try:
        main()
    except Exception as e:  # noqa: BLE001  (every failure goes through one policy)
        on_bridge_error(e)
