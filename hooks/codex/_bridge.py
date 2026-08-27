# hooks/codex/_bridge.py
# Shared helpers for the Codex hook adapters (pre-/post-tool-use).
# Keeps the apply_patch parsing, repo-root resolution, env setup, and the
# "synthesize a Claude-shaped payload and run a hooks/*.sh subprocess" pattern in ONE place
# so the two adapters cannot drift (and the guard/lint logic stays single-sourced in the .sh).
import json
import os
import re
import subprocess
import sys

# Repo root = two levels up from hooks/codex/.
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))

_ADD_UPDATE = re.compile(r"^\*\*\* (Add|Update) File: (.+)$")
_MOVE_TO = re.compile(r"^\*\*\* Move to: (.+)$")
_FRAME = re.compile(r"^\*\*\* (Delete File|End Patch|Begin Patch)")


def read_payload():
    """Parse the Codex hook JSON from stdin; return {} on failure (fail open)."""
    try:
        return json.load(sys.stdin)
    except Exception:
        return {}


def parse_targets(tool_input):
    """Return [(path, full_content_or_None)] for each write target in a Codex payload.

    Handles the direct Edit/Write shape (tool_input.file_path) and the apply_patch envelope
    (patch text in tool_input.command), reconstructing whole-file content for Add hunks.
    Callers that only need paths iterate `for path, _ in parse_targets(...)`.
    """
    fp = tool_input.get("file_path")
    if fp:
        return [(fp, tool_input.get("content"))]
    cmd = tool_input.get("command")
    if not isinstance(cmd, str):
        return []
    targets = []
    cur_path, is_add, buf = None, False, []

    def flush():
        if cur_path is not None:
            targets.append((cur_path, "".join(buf) if is_add else None))

    for line in cmd.splitlines():
        m = _ADD_UPDATE.match(line)
        mv = _MOVE_TO.match(line)
        if m:
            flush()
            cur_path, is_add, buf = m.group(2).strip(), (m.group(1) == "Add"), []
        elif _FRAME.match(line):
            flush()
            cur_path, is_add, buf = None, False, []
        elif mv:
            targets.append((mv.group(1).strip(), None))
        elif cur_path is not None and is_add and line.startswith("+"):
            buf.append(line[1:] + "\n")
    flush()
    return targets


def bridge_env(cwd):
    """Environment for the shell hooks: point them at the plugin root + the session cwd."""
    env = dict(os.environ)
    env["CLAUDE_PLUGIN_ROOT"] = ROOT
    env["CLAUDE_PROJECT_DIR"] = cwd
    return env


def run_hook(script_name, path, content, cwd, env):
    """Synthesize the Claude-shaped payload for `path` and run hooks/<script_name>.
    Returns the CompletedProcess (returncode / stdout / stderr)."""
    tool_input = {"file_path": path}
    if content is not None:
        tool_input["content"] = content
    synth = {"tool_name": "Write", "tool_input": tool_input}
    return subprocess.run(
        ["bash", os.path.join(ROOT, "hooks", script_name)],
        input=json.dumps(synth), text=True, capture_output=True, cwd=cwd, env=env,
    )
