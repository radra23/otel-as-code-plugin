# hooks/copilot/_copilot.py
# Shared helpers for the GitHub Copilot CLI hook adapters (pre-/post-tool-use).
#
# Copilot's camelCase hook payload is {sessionId, timestamp, cwd, toolName, toolArgs}, where
# toolArgs is a JSON STRING, and its file tools are `create` {path, file_text} and `edit`
# {path, old_str, new_str} (measured on Copilot CLI 1.0.56, tests/hooks/fixtures/copilot/). This
# module turns that into the Claude-shaped Write/Edit the unchanged hooks/*.sh read. Running the
# scripts, the env they get and the context-cache checks come from hooks/codex/_bridge.py, so the
# two bridges share one copy of that plumbing.
import json
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "codex"))
from _bridge import (  # noqa: E402  (path set just above)
    bridge_env, is_context_path, resolves_to_cache, run_hook, unconfirmed_on_disk)

__all__ = ["bridge_env", "claude_tool", "is_context_path", "read_payload", "resolves_to_cache",
           "run_hook", "unconfirmed_on_disk"]


def read_payload():
    """Parse the Copilot hook JSON from stdin; {} when it isn't JSON."""
    try:
        payload = json.load(sys.stdin)
    except ValueError:
        return {}
    return payload if isinstance(payload, dict) else {}


def claude_tool(payload):
    """(tool_name, tool_input) as Claude Code would send it for a Copilot file write, or None.

    Only the two tools measured are mapped. A flat Copilot hook entry fires for every tool
    (report_intent, shell, view, ...), so anything else is not a write this bridge can check and
    is let through, as the Claude Code hooks let through every tool but Write and Edit."""
    args = payload.get("toolArgs")
    if isinstance(args, str):
        try:
            args = json.loads(args)
        except ValueError:
            return None
    if not isinstance(args, dict) or not isinstance(args.get("path"), str) or not args["path"]:
        return None
    tool = payload.get("toolName")
    if tool == "create":
        return "Write", {"file_path": args["path"], "content": args.get("file_text", "")}
    if tool == "edit":
        return "Edit", {"file_path": args["path"], "old_string": args.get("old_str", ""),
                        "new_string": args.get("new_str", "")}
    return None
