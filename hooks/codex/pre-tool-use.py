#!/usr/bin/env python3
# hooks/codex/pre-tool-use.py
# Codex PreToolUse adapter for otel-as-code.
#
# Codex delivers file edits as tool_name="apply_patch" with the patch text in
# tool_input.command (not a clean file_path), and expects a JSON permissionDecision on
# stdout. This adapter parses the patch, then REUSES hooks/write-guard.sh as the single
# source of guard logic (overwrite protection + confirm-before-write) by synthesizing the
# Claude-shaped payload write-guard.sh already understands, and maps its exit code (1=block)
# to Codex's { hookSpecificOutput.permissionDecision: "deny" }.
#
# Scope note: for apply_patch "Update File" hunks we only have a diff, not the full new
# content, so the confirm-before-write check on otel-context.json runs only for whole-file
# writes ("Add File" / Write with content). Overwrite protection works for all cases (it
# needs only the target path + on-disk existence).
import json
import os
import re
import subprocess
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
WRITE_GUARD = os.path.join(ROOT, "hooks", "write-guard.sh")


def parse_targets(tool_input):
    """Yield (path, full_content_or_None) for each write target."""
    targets = []
    fp = tool_input.get("file_path")
    if fp:
        targets.append((fp, tool_input.get("content")))
        return targets
    cmd = tool_input.get("command")
    if not isinstance(cmd, str):
        return targets
    cur_path, is_add, buf = None, False, []
    def flush():
        if cur_path is not None:
            targets.append((cur_path, "".join(buf) if is_add else None))
    for line in cmd.splitlines():
        m = re.match(r"^\*\*\* (Add|Update) File: (.+)$", line)
        mv = re.match(r"^\*\*\* Move to: (.+)$", line)
        if m:
            flush()
            cur_path, is_add, buf = m.group(2).strip(), (m.group(1) == "Add"), []
        elif re.match(r"^\*\*\* (Delete File|End Patch|Begin Patch)", line):
            flush()
            cur_path, is_add, buf = None, False, []
        elif mv:
            targets.append((mv.group(1).strip(), None))
        elif cur_path is not None and is_add and line.startswith("+"):
            buf.append(line[1:] + "\n")
    flush()
    return targets


def main():
    try:
        payload = json.load(sys.stdin)
    except Exception:
        sys.exit(0)  # unparseable input -> allow (fail open, like the advisory hooks)
    tool_input = payload.get("tool_input") or {}
    cwd = payload.get("cwd") or os.getcwd()
    env = dict(os.environ)
    env["CLAUDE_PLUGIN_ROOT"] = ROOT
    env["CLAUDE_PROJECT_DIR"] = cwd

    for path, content in parse_targets(tool_input):
        synth = {"tool_name": "Write", "tool_input": {"file_path": path}}
        if content is not None:
            synth["tool_input"]["content"] = content
        proc = subprocess.run(
            ["bash", WRITE_GUARD], input=json.dumps(synth),
            text=True, capture_output=True, cwd=cwd, env=env,
        )
        if proc.returncode == 1:
            reason = (proc.stderr or "otel-as-code guardrail blocked this write.").strip()
            print(json.dumps({"hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "deny",
                "permissionDecisionReason": reason,
            }}))
            sys.exit(0)
    sys.exit(0)  # no target blocked -> allow


if __name__ == "__main__":
    main()
