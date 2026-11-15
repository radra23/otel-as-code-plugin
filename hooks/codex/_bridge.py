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


# Marks an Update hunk the adapter could not apply to the file on disk, so its result is unknown.
UNAPPLIED = object()


def parse_targets(tool_input, cwd=None):
    """Return [(path, full_content_or_None)] for each write target in a Codex payload.

    Handles the direct Edit/Write shape (tool_input.file_path) and the apply_patch envelope
    (patch text in tool_input.command). Add hunks carry their whole content. With `cwd` (the
    PreToolUse case, before the patch lands), an Update hunk carries the file as the patch would
    leave it, rebuilt from the file on disk, or UNAPPLIED when its lines can't be found there; a
    "*** Move to:" destination gets the same content. Without `cwd`, Update content is None.
    Callers that only need paths iterate `for path, _ in parse_targets(...)`.
    """
    fp = tool_input.get("file_path")
    if fp:
        return [(fp, tool_input.get("content"))]
    cmd = tool_input.get("command")
    if not isinstance(cmd, str):
        return []
    targets = []
    cur_path, is_add, buf, move_to = None, False, [], None

    def flush():
        if cur_path is None:
            return
        if is_add:
            content = "".join(line[1:] + "\n" for line in buf if line.startswith("+"))
        elif cwd is not None:
            content = apply_update(os.path.join(cwd, cur_path), buf)
        else:
            content = None
        targets.append((cur_path, content))
        if move_to is not None:
            targets.append((move_to, content))

    for line in cmd.splitlines():
        m = _ADD_UPDATE.match(line)
        mv = _MOVE_TO.match(line)
        if m:
            flush()
            cur_path, is_add, buf, move_to = m.group(2).strip(), (m.group(1) == "Add"), [], None
        elif _FRAME.match(line):
            flush()
            cur_path, is_add, buf, move_to = None, False, [], None
        elif mv and cur_path is not None:
            move_to = mv.group(1).strip()
        elif cur_path is not None:
            buf.append(line)
    flush()
    return targets


def apply_update(path, hunk_lines):
    """The text of `path` after an apply_patch Update hunk, or UNAPPLIED.

    Each "@@" starts a chunk; text after "@@ " is a line to find first. In a chunk, " " lines are
    context, "-" lines are removed and "+" lines added, so the chunk's old lines (" " and "-") are
    found in order and replaced by its new lines (" " and "+"). Lines are compared exactly, then
    ignoring trailing and then surrounding whitespace, as apply_patch itself does.
    """
    try:
        with open(path, encoding="utf-8") as f:
            text = f.read()
    except (OSError, UnicodeDecodeError):
        return UNAPPLIED
    lines = text.split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    chunks = []
    for line in hunk_lines:
        if line.startswith("@@"):
            chunks.append({"anchor": line[2:].strip(), "lines": []})
        elif line.startswith("*** End of File"):
            continue
        else:
            if not chunks:
                chunks.append({"anchor": "", "lines": []})
            chunks[-1]["lines"].append(line)
    pos = 0
    for chunk in chunks:
        if chunk["anchor"]:
            at = _find(lines, [chunk["anchor"]], pos)
            if at < 0:
                return UNAPPLIED
            pos = at + 1
        old = [l[1:] for l in chunk["lines"] if l[:1] in (" ", "-") or l == ""]
        new = [l[1:] for l in chunk["lines"] if l[:1] in (" ", "+") or l == ""]
        if not old:
            at = len(lines)  # a chunk of additions only is appended
        else:
            at = _find(lines, old, pos)
            if at < 0:
                return UNAPPLIED
        lines[at:at + len(old)] = new
        pos = at + len(new)
    return "\n".join(lines) + "\n"


def _find(lines, seq, start):
    for norm in (lambda s: s, str.rstrip, str.strip):
        want = [norm(s) for s in seq]
        for i in range(start, len(lines) - len(seq) + 1):
            if [norm(s) for s in lines[i:i + len(seq)]] == want:
                return i
    return -1


def bridge_env(cwd):
    """Environment for the shell hooks: point them at the plugin root + the session cwd."""
    env = dict(os.environ)
    env["CLAUDE_PLUGIN_ROOT"] = ROOT
    env["CLAUDE_PROJECT_DIR"] = cwd
    return env


def run_hook(script_name, path, content, cwd, env, tool=None):
    """Synthesize the Claude-shaped payload for `path` and run hooks/<script_name>.
    `tool` = (tool_name, tool_input) passes a direct Edit/Write through unchanged, so the hook
    sees exactly what Claude Code would send. Returns the CompletedProcess."""
    if tool is not None:
        synth = {"tool_name": tool[0], "tool_input": tool[1]}
    else:
        tool_input = {"file_path": path}
        if content is not None:
            tool_input["content"] = content
        synth = {"tool_name": "Write", "tool_input": tool_input}
    return subprocess.run(
        ["bash", os.path.join(ROOT, "hooks", script_name)],
        input=json.dumps(synth), text=True, capture_output=True, cwd=cwd, env=env,
    )


def is_context_path(path):
    """True when `path` is the context cache, by hooks/otel-force-match.py's own normalisation
    (the one write-guard uses), loaded from that file rather than restated here."""
    import importlib.util
    spec = importlib.util.spec_from_file_location(
        "otel_force_match", os.path.join(ROOT, "hooks", "otel-force-match.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod.is_context(path)
